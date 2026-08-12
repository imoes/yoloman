"""Offline tests for the disk-ops compiler + safety gate (no host)."""
from bossman.services import disk_ops as do


def test_target_device_derivation():
    assert do._target_device({"target": "/dev/sda2"}) == "/dev/sda"
    assert do._target_device({"target": "/dev/loop0"}) == "/dev/loop0"
    assert do._target_device({"target": "/dev/nvme0n1p2"}) == "/dev/nvme0n1"
    assert do._target_device({"device": "/dev/sdb"}) == "/dev/sdb"


def test_compile_ops():
    steps = do.compile({"ops": [
        {"op": "mklabel", "device": "/dev/loop0", "table": "gpt"},
        {"op": "mkpart", "device": "/dev/loop0", "fstype": "ext4", "start": "1MiB", "end": "100%"},
        {"op": "mkfs", "target": "/dev/loop0p1", "fstype": "ext4"},
        {"op": "delete", "device": "/dev/loop0", "num": 1},
        {"op": "mkfs", "target": "/dev/loop0", "fstype": "weirdfs"},
    ]})
    assert steps[0]["argv"] == ["parted", "-s", "/dev/loop0", "mklabel", "gpt"] and steps[0]["touches_table"]
    assert steps[1]["argv"][:6] == ["parted", "-s", "-a", "optimal", "/dev/loop0", "mkpart"]
    assert steps[2]["argv"] == ["mkfs.ext4", "-F", "/dev/loop0p1"] and steps[2]["touches_table"] is False
    assert steps[3]["argv"] == ["parted", "-s", "/dev/loop0", "rm", "1"]
    assert steps[4].get("error")  # unsupported fstype flagged


def test_safety_refuses_nonloop_without_flag():
    steps = do.compile({"ops": [{"op": "mkfs", "target": "/dev/sda1", "device": "/dev/sda", "fstype": "ext4"}]})
    probs = do.safety_check(steps, {"devices": []}, allow_nonloop=False)
    assert any(p["severity"] == "error" and "loopback" in p["message"] for p in probs)
    assert do.safety_check(steps, {"devices": []}, allow_nonloop=True) == []  # allowed with the flag


def test_safety_refuses_busy_target():
    steps = do.compile({"ops": [{"op": "mkfs", "target": "/dev/loop0", "device": "/dev/loop0", "fstype": "ext4"}]})
    layout = {"devices": [{"partitions": [{"path": "/dev/loop0", "busy": True, "children": []}]}]}
    probs = do.safety_check(steps, layout, allow_nonloop=False)
    assert any("mounted" in p["message"] for p in probs)


def test_umount_and_lvextend_compile():
    steps = do.compile({"ops": [
        {"op": "umount", "device": "/dev/sdb", "target": "/dev/sdb1"},
        {"op": "lvextend", "device": "/dev/rootvg/var", "target": "/dev/rootvg/var", "size": "+100%FREE"},
        {"op": "lvextend", "device": "/dev/rootvg/var", "target": "/dev/rootvg/var", "size": "+5G"},
    ]})
    assert steps[0]["argv"] == ["umount", "/dev/sdb1"]
    assert steps[1]["argv"] == ["lvextend", "--resizefs", "-l", "+100%FREE", "/dev/rootvg/var"]  # % → -l
    assert steps[2]["argv"] == ["lvextend", "--resizefs", "-L", "+5G", "/dev/rootvg/var"]        # size → -L


def test_umount_refuses_critical_mount_but_allows_data():
    layout = {"devices": [{"path": "/dev/sda", "partitions": [
        {"path": "/dev/sda1", "busy": True, "mountpoint": "/", "children": []},
        {"path": "/dev/sdb1", "busy": True, "mountpoint": "/mnt/data", "children": []},
    ]}]}
    crit = do.compile({"ops": [{"op": "umount", "device": "/dev/sda", "target": "/dev/sda1"}]})
    assert any("critical system mount" in p["message"] for p in do.safety_check(crit, layout, allow_nonloop=True))
    data = do.compile({"ops": [{"op": "umount", "device": "/dev/sda", "target": "/dev/sdb1"}]})
    assert do.safety_check(data, layout, allow_nonloop=True) == []  # /mnt/data unmount is fine


def test_lvextend_refuses_non_grow():
    shrink = do.compile({"ops": [{"op": "lvextend", "device": "/dev/vg/lv", "target": "/dev/vg/lv", "size": "10G"}]})
    assert any("online GROW" in p["message"] for p in do.safety_check(shrink, {"devices": []}, allow_nonloop=True))


def test_resize_shrink_compiles_in_safe_order():
    # shrink ext4: fsck → resize2fs <size> → parted resizepart (fs before partition)
    steps = do.compile({"ops": [{"op": "resize", "device": "/dev/sdb", "target": "/dev/sdb1",
                                 "num": 1, "fstype": "ext4", "start_mib": 1, "size_mib": 8192, "grow": False}]})
    assert steps[0]["argv"] == ["e2fsck", "-f", "-y", "/dev/sdb1"]
    assert steps[1]["argv"] == ["resize2fs", "/dev/sdb1", "8192M"]
    # partition shrink goes through sh -c (parted needs a tty + "Yes" on shrink); +2 MiB margin
    assert steps[2]["argv"][:2] == ["sh", "-c"] and "resizepart 1 8195MiB" in steps[2]["argv"][2]
    assert steps[2]["touches_table"] and not steps[1]["touches_table"]


def test_resize_grow_compiles_partition_before_fs():
    # grow: parted resizepart (bigger) → resize2fs (fill) — partition before fs
    steps = do.compile({"ops": [{"op": "resize", "device": "/dev/sdb", "target": "/dev/sdb1",
                                 "num": 1, "fstype": "ext4", "start_mib": 1, "size_mib": 20480, "grow": True}]})
    assert steps[0]["argv"] == ["parted", "-s", "/dev/sdb", "unit", "MiB", "resizepart", "1", "20481MiB"]
    assert steps[1]["argv"] == ["resize2fs", "/dev/sdb1"]


def test_resize_refuses_xfs_and_mounted():
    xfs = do.compile({"ops": [{"op": "resize", "device": "/dev/sdb", "target": "/dev/sdb1",
                               "num": 1, "fstype": "xfs", "size_mib": 4096}]})
    assert any(p["severity"] == "error" for p in do.safety_check(xfs, {"devices": []}, allow_nonloop=True))
    ext = do.compile({"ops": [{"op": "resize", "device": "/dev/sdb", "target": "/dev/sdb1",
                               "num": 1, "fstype": "ext4", "start_mib": 1, "size_mib": 4096}]})
    layout = {"devices": [{"path": "/dev/sdb", "partitions": [
        {"path": "/dev/sdb1", "busy": True, "mountpoint": "/mnt/data", "children": []}]}]}
    # mounted target → refused (can't shrink a mounted ext fs); note the whole disk is protected too
    assert any("unmount" in p["message"].lower() for p in do.safety_check(ext, layout, allow_nonloop=True))
