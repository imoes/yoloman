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


def test_lvreduce_compiles_and_refuses_grow_and_mounted():
    steps = do.compile({"ops": [{"op": "lvreduce", "device": "/dev/mapper/vg-data",
                                 "target": "/dev/mapper/vg-data", "size": "8G"}]})
    assert steps[0]["argv"] == ["lvreduce", "-y", "--resizefs", "-L", "8G", "/dev/mapper/vg-data"]
    # a "+size" is a grow, not a shrink → flagged
    grow = do.compile({"ops": [{"op": "lvreduce", "device": "/dev/vg/lv", "target": "/dev/vg/lv", "size": "+5G"}]})
    assert any(p["severity"] == "error" for p in do.safety_check(grow, {"devices": []}, allow_nonloop=True))
    # a mounted LV → refused (ext can't shrink mounted)
    layout = {"devices": [{"path": "/dev/sda", "partitions": [{"path": "/dev/sda2", "busy": False, "children": [
        {"path": "/dev/mapper/vg-data", "kind": "lvm", "busy": True, "mountpoint": "/mnt/data", "children": []}]}]}]}
    assert any("unmount" in p["message"].lower() for p in do.safety_check(steps, layout, allow_nonloop=True))


def test_grown_disk_chain_compiles_and_is_allowed_on_the_system_disk():
    """The hypervisor-grew-the-disk chain: fix GPT → grow the last partition → let the
    PV see the new extents → grow the LV. All online, so it must be allowed even on a
    disk carrying mounted filesystems (the usual case: a grown VM system disk)."""
    steps = do.compile({"ops": [
        {"op": "gptfix", "device": "/dev/sda"},
        {"op": "growpart", "device": "/dev/sda", "num": 1},
        {"op": "pvresize", "device": "/dev/sda", "target": "/dev/sda1"},
        {"op": "lvextend", "device": "/dev/rootvg/usr", "target": "/dev/rootvg/usr", "size": "+100%FREE"},
    ]})
    assert steps[0]["argv"] == ["sgdisk", "-e", "/dev/sda"]
    assert steps[1]["argv"][:2] == ["sh", "-c"] and "resizepart 1 100%" in steps[1]["argv"][2]
    assert steps[2]["argv"] == ["pvresize", "/dev/sda1"]
    assert steps[3]["argv"] == ["lvextend", "--resizefs", "-l", "+100%FREE", "/dev/rootvg/usr"]
    # /dev/sda holds the mounted root → normally protected, but this chain is exempt
    layout = {"devices": [{"path": "/dev/sda", "partitions": [
        {"path": "/dev/sda1", "busy": False, "children": [
            {"path": "/dev/rootvg/usr", "kind": "lvm", "busy": True, "mountpoint": "/usr", "children": []}]}]}]}
    assert do.safety_check(steps, layout, allow_nonloop=True) == []


def test_movepart_uses_the_native_copier_then_rewrites_the_table():
    """A real move: copy the bytes with the agent's disk_move module, wait for that
    job, and only then repoint the partition. Copy first, table second."""
    steps = do.compile({"ops": [{"op": "movepart", "device": "/dev/sdb", "num": 1,
                                 "sector_size": 512, "src_start_s": 2048,
                                 "dst_start_s": 22528, "length_s": 20480}]})
    assert steps[0]["tool"] == "disk_move"
    assert steps[0]["params"] == {"action": "start", "device": "/dev/sdb",
                                  "src_offset": 2048 * 512, "dst_offset": 22528 * 512,
                                  "length": 20480 * 512}
    assert "backwards" in steps[0]["desc"]          # dst > src → overlapping direction
    assert steps[1]["poll"] == "disk_move"
    assert steps[2]["touches_table"] and "mkpart" in steps[2]["argv"][2]
    # nothing else on the disk → allowed
    layout = {"devices": [{"path": "/dev/sdb", "partitions": [
        {"path": "/dev/sdb1", "busy": False, "start_s": 2048, "end_s": 22527, "children": []}]}]}
    assert do.safety_check(steps, layout, allow_nonloop=True) == []


def test_movepart_refuses_a_destination_that_overlaps_another_partition():
    steps = do.compile({"ops": [{"op": "movepart", "device": "/dev/sdb", "num": 1,
                                 "sector_size": 512, "src_start_s": 2048,
                                 "dst_start_s": 40960, "length_s": 20480}]})
    layout = {"devices": [{"path": "/dev/sdb", "partitions": [
        {"path": "/dev/sdb1", "busy": False, "start_s": 2048, "end_s": 22527, "children": []},
        {"path": "/dev/sdb2", "busy": False, "start_s": 40960, "end_s": 81919, "children": []}]}]}
    probs = do.safety_check(steps, layout, allow_nonloop=True)
    assert any("overlaps /dev/sdb2" in p["message"] for p in probs)


def test_movepart_refuses_a_mounted_partition():
    steps = do.compile({"ops": [{"op": "movepart", "device": "/dev/sdb", "num": 1,
                                 "sector_size": 512, "src_start_s": 22528,
                                 "dst_start_s": 2048, "length_s": 20480}]})
    layout = {"devices": [{"path": "/dev/sdb", "partitions": [
        {"path": "/dev/sdb1", "busy": True, "mountpoint": "/mnt/x",
         "start_s": 22528, "end_s": 43007, "children": []}]}]}
    assert any("unmount" in p["message"].lower() for p in do.safety_check(steps, layout, allow_nonloop=True))


def test_zfs_ops_compile():
    steps = do.compile({"ops": [
        {"op": "zfs_create", "name": "tank/data", "mountpoint": "/data"},
        {"op": "zfs_set", "name": "tank/data", "property": "refquota", "size": "8G"},
        {"op": "zfs_snapshot", "name": "tank/data", "snap": "before"},
        {"op": "zfs_destroy", "name": "tank/old", "recursive": True},
        {"op": "zpool_create", "name": "tank", "raid": "mirror", "vdevs": ["/dev/loop0", "/dev/loop1"]},
    ]})
    assert steps[0]["argv"] == ["zfs", "create", "-o", "mountpoint=/data", "tank/data"]
    assert steps[1]["argv"] == ["zfs", "set", "refquota=8G", "tank/data"]           # the ZFS "resize"
    assert steps[2]["argv"] == ["zfs", "snapshot", "tank/data@before"]
    assert steps[3]["argv"] == ["zfs", "destroy", "-r", "tank/old"]
    assert steps[4]["argv"] == ["zpool", "create", "-f", "tank", "mirror", "/dev/loop0", "/dev/loop1"]


def test_zfs_set_rejects_bad_property():
    steps = do.compile({"ops": [{"op": "zfs_set", "name": "tank/x", "property": "compression", "size": "on"}]})
    assert any(p["severity"] == "error" for p in do.safety_check(steps, {"devices": []}, allow_nonloop=True))


def test_zfs_destroy_refuses_critical_mount():
    layout = {"devices": [], "zfs": {"available": True, "datasets": [
        {"name": "rpool", "mountpoint": "/"}, {"name": "rpool/ROOT", "mountpoint": "/"}]}}
    steps = do.compile({"ops": [{"op": "zpool_destroy", "name": "rpool"}]})
    assert any("critical" in p["message"] for p in do.safety_check(steps, layout, allow_nonloop=True))
    # a data pool with no critical mount is allowed
    ok = do.compile({"ops": [{"op": "zfs_destroy", "name": "tank/scratch"}]})
    assert do.safety_check(ok, {"devices": [], "zfs": {"datasets": [{"name": "tank/scratch", "mountpoint": "/tank/scratch"}]}}, allow_nonloop=True) == []


def test_zpool_create_guards_vdevs():
    steps = do.compile({"ops": [{"op": "zpool_create", "name": "tank", "vdevs": ["/dev/sdb1"]}]})
    # real disk without the flag → refused; with the flag → allowed
    assert any("loopback" in p["message"] for p in do.safety_check(steps, {"devices": []}, allow_nonloop=False))
    assert do.safety_check(steps, {"devices": []}, allow_nonloop=True) == []
    # a vdev on a disk that carries a mounted fs → refused even with the flag
    layout = {"devices": [{"path": "/dev/sdb", "partitions": [
        {"path": "/dev/sdb2", "busy": True, "mountpoint": "/", "children": []}]}]}
    assert any("mounted" in p["message"] for p in do.safety_check(
        do.compile({"ops": [{"op": "zpool_create", "name": "t", "vdevs": ["/dev/sdb1"]}]}), layout, allow_nonloop=True))


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
