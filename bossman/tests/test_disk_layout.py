"""Offline tests for the disk-layout parsers (no host)."""
import asyncio

from bossman.services import disk_layout as dl

_PARTED = """BYT;
/dev/sda:976773168s:scsi:512:4096:gpt:ATA Disk:;
1:2048s:1050623s:1048576s:fat32:EFI:boot,esp;
2:1050624s:976771071s:975720448s:ext4:root:;
1:976771072s:976773134s:2063s:free;
"""


def test_parse_parted():
    table, segs, sector = dl._parse_parted(_PARTED)
    assert table == "gpt" and sector == 512
    free = [s for s in segs if s["free"]]
    parts = [s for s in segs if not s["free"]]
    assert len(free) == 1 and free[0]["start_s"] == 976771072
    assert [(p["num"], p["start_s"], p["end_s"]) for p in parts] == [(1, 2048, 1050623), (2, 1050624, 976771071)]


def test_partition_from_lsblk_mountpoints_array_and_busy():
    node = {"name": "sda2", "path": "/dev/sda2", "type": "part", "size": "975720448",
            "fstype": "ext4", "label": "root", "mountpoints": ["/", None],
            "fsused": "1000", "fsavail": "5000", "partflags": "boot,esp"}
    p = dl._partition_from_lsblk(node)
    assert p["mountpoint"] == "/" and p["busy"] is True
    assert p["avail_bytes"] == 5000 and p["flags"] == ["boot", "esp"]


def test_partition_unmounted_not_busy():
    p = dl._partition_from_lsblk({"name": "sdb1", "type": "part", "size": "100", "mountpoints": [None]})
    assert p["busy"] is False and p["mountpoint"] is None


_MDSTAT = """Personalities : [raid1] [raid6] [raid5] [raid4]
md0 : active raid1 sdb2[1] sdb1[0]
      2094080 blocks super 1.2 [2/2] [UU]

md1 : active raid5 sdd1[3](S) sdc1[2](F) sdb3[1] sda3[0]
      4190208 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/2] [UU_]
      [====>................]  recovery = 20.5% (430080/2094080) finish=1.2min speed=21504K/sec

unused devices: <none>
"""


def test_parse_mdstat_healthy_and_degraded():
    arrays = dl._parse_mdstat(_MDSTAT)
    assert [a["name"] for a in arrays] == ["md0", "md1"]

    md0 = arrays[0]
    assert md0["level"] == "raid1" and md0["state"] == "active"
    assert md0["size_bytes"] == 2094080 * 1024          # mdstat counts KiB
    assert md0["degraded"] is False and md0["expected"] == 2 and md0["present"] == 2
    assert [(d["path"], d["role"], d["state"]) for d in md0["devices"]] == [
        ("/dev/sdb2", 1, "in-sync"), ("/dev/sdb1", 0, "in-sync")]

    md1 = arrays[1]
    assert md1["level"] == "raid5"
    assert md1["degraded"] is True and md1["slots"] == "UU_"   # a slot is missing
    states = {d["path"]: d["state"] for d in md1["devices"]}
    assert states["/dev/sdd1"] == "spare" and states["/dev/sdc1"] == "failed"
    assert states["/dev/sdb3"] == "in-sync"
    assert md1["sync"] == {"action": "recovery", "percent": 20.5, "finish": "1.2min"}


def test_parse_mdstat_no_arrays():
    assert dl._parse_mdstat("Personalities : [raid1]\nunused devices: <none>\n") == []


class _FakeMdClient:
    def __init__(self, mdstat: str | None):
        self._mdstat = mdstat

    async def call_tool(self, name, params):
        argv = params["argv"]
        if argv[:1] == ["cat"] and self._mdstat is None:
            return {"data": {"rc": 1, "stdout": "", "stderr": "No such file"}}
        if argv[:1] == ["cat"]:
            return {"data": {"rc": 0, "stdout": self._mdstat, "stderr": ""}}
        # mdadm --detail: pretend the binary is missing → detail is optional
        return {"data": {"rc": 127, "stdout": "", "stderr": "mdadm: not found"}}


def test_read_mdraid_works_without_the_mdadm_binary():
    md = asyncio.run(dl._read_mdraid(_FakeMdClient(_MDSTAT)))
    assert md["available"] is True and len(md["arrays"]) == 2


def test_read_mdraid_absent_degrades():
    assert asyncio.run(dl._read_mdraid(_FakeMdClient(None))) == {"available": False}


class _FakeZfsClient:
    """Returns canned `zpool list`/`zfs list` output so _read_zfs's parser can be
    exercised without a loaded ZFS module (which needs a signed kernel module)."""
    def __init__(self, pools: str, datasets: str, ok: bool = True):
        self._pools, self._datasets, self._ok = pools, datasets, ok

    async def call_tool(self, name, params):
        argv = params["argv"]
        if not self._ok:
            return {"data": {"rc": 1, "stdout": "", "stderr": "Failed to load ZFS module"}}
        out = self._pools if argv[:2] == ["zpool", "list"] else self._datasets
        return {"data": {"rc": 0, "stdout": out, "stderr": ""}}


def test_read_zfs_parses_pools_and_datasets():
    pools = "tank\t8000000000\t2000000000\t6000000000\tONLINE\t1%\t25\n"
    # name type used avail refer quota refquota reservation refreservation mountpoint
    datasets = (
        "tank\tfilesystem\t2000000000\t6000000000\t100000\t-\t-\t-\t-\t/tank\n"
        "tank/data\tfilesystem\t1500000000\t6000000000\t1500000000\t-\t8000000000\t-\t-\t/tank/data\n"
        "tank/data@snap1\tsnapshot\t0\t-\t1500000000\t-\t-\t-\t-\t-\n"
    )
    zfs = asyncio.run(dl._read_zfs(_FakeZfsClient(pools, datasets)))
    assert zfs["available"] is True and len(zfs["pools"]) == 1
    assert zfs["pools"][0] == {"name": "tank", "size_bytes": 8000000000, "alloc_bytes": 2000000000,
                               "free_bytes": 6000000000, "health": "ONLINE", "frag": "1%", "cap": "25"}
    ds = {d["name"]: d for d in zfs["datasets"]}
    assert ds["tank/data"]["refquota_bytes"] == 8000000000 and ds["tank/data"]["mountpoint"] == "/tank/data"
    assert ds["tank/data"]["quota_bytes"] is None          # '-' → None
    assert ds["tank/data@snap1"]["type"] == "snapshot" and ds["tank/data@snap1"]["mountpoint"] is None


def test_read_zfs_absent_degrades():
    zfs = asyncio.run(dl._read_zfs(_FakeZfsClient("", "", ok=False)))
    assert zfs == {"available": False}
