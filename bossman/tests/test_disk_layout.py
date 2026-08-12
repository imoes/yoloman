"""Offline tests for the disk-layout parsers (no host)."""
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
