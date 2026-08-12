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
