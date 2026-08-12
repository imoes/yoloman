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
    assert any("mounted/busy" in p["message"] for p in probs)


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
