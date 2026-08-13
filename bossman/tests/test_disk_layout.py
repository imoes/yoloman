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
