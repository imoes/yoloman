"""Phase 3a: the imaging plan — pure, no DB, no subprocess.

The fixtures are this host's real layout (`lsblk -b --json`), because it happens to contain both
shapes the plan has to handle: LVM on a partition (sda3 → ubuntu--vg) and LVM straight on the
disk with no partition table (sdb → data--vg).
"""

import pytest

from bossman.services.imaging import (
    ALIGN,
    Disk,
    ImagingError,
    PlannedVolume,
    SourceLayout,
    Volume,
    candidate_disks,
    plan_restore,
    select_target_disk,
)

GiB = 1024**3

# Real output from this host, trimmed: two disks plus the eight loop devices snaps leave behind.
LSBLK = [
    {"name": "loop0", "type": "loop", "rm": False, "size": 4096},
    {"name": "loop1", "type": "loop", "rm": False, "size": 847872},
    {"name": "sda", "type": "disk", "rm": False, "size": 53687091200},
    {"name": "sdb", "type": "disk", "rm": False, "size": 182536110080},
    {"name": "sr0", "type": "rom", "rm": True, "size": 1073741824},
]

ESP = Volume(role="esp", fs_type="vfat", size_bytes=1 * GiB, used_bytes=8 * 1024**2, partition=1)
BOOT = Volume(role="boot", fs_type="ext4", size_bytes=2 * GiB, used_bytes=300 * 1024**2, partition=2)
ROOT_EXT4 = Volume(
    role="root", fs_type="ext4", size_bytes=40 * GiB, used_bytes=6 * GiB,
    vg="ubuntu-vg", lv="ubuntu-lv", mountpoint="/",
)
ROOT_XFS = Volume(
    role="root", fs_type="xfs", size_bytes=40 * GiB, used_bytes=6 * GiB,
    vg="ubuntu-vg", lv="ubuntu-lv", mountpoint="/",
)


def _layout(root: Volume = ROOT_EXT4, **kw) -> SourceLayout:
    return SourceLayout(disk_size=50 * GiB, volumes=(ESP, BOOT, root), **kw)


# ---------------------------------------------------------------------------
# Which disk do we install onto


def test_loop_and_rom_devices_are_never_candidates():
    """This host has eight loop devices from snaps; a restore must not consider them."""
    names = [d.name for d in candidate_disks(LSBLK)]
    assert names == ["sdb", "sda"], "largest first, and only real disks"


def test_removable_devices_are_excluded():
    """Very often the medium the operator booted from."""
    devs = LSBLK + [{"name": "sdc", "type": "disk", "rm": True, "size": 64 * GiB}]
    assert "sdc" not in [d.name for d in candidate_disks(devs)]


def test_the_largest_disk_is_chosen_not_sda():
    """`sda` is wrong on any NVMe machine (`nvme0n1`), and hardcoding it there either fails or —
    much worse — overwrites the wrong device."""
    assert select_target_disk(LSBLK).name == "sdb"

    nvme = [
        {"name": "nvme0n1", "type": "disk", "rm": False, "size": 512 * GiB},
        {"name": "sda", "type": "disk", "rm": False, "size": 50 * GiB},
    ]
    assert select_target_disk(nvme).name == "nvme0n1"


def test_an_explicit_choice_wins_and_a_bogus_one_is_refused():
    assert select_target_disk(LSBLK, prefer="sda").name == "sda"
    with pytest.raises(ImagingError) as exc:
        select_target_disk(LSBLK, prefer="loop0")
    assert "candidates" in str(exc.value), "say what could have been chosen instead"


def test_no_disk_at_all_is_an_error_not_a_guess():
    with pytest.raises(ImagingError):
        select_target_disk([{"name": "loop0", "type": "loop", "rm": False, "size": 4096}])


def test_candidate_order_is_total_so_installs_are_reproducible():
    """Same-size disks must not depend on kernel enumeration order."""
    same = [
        {"name": "sdb", "type": "disk", "rm": False, "size": 100 * GiB},
        {"name": "sda", "type": "disk", "rm": False, "size": 100 * GiB},
    ]
    assert [d.name for d in candidate_disks(same)] == ["sda", "sdb"]
    assert [d.name for d in candidate_disks(list(reversed(same)))] == ["sda", "sdb"]


# ---------------------------------------------------------------------------
# Fitting the layout onto the target


def test_the_last_volume_absorbs_a_bigger_disk():
    plan = plan_restore(_layout(), Disk("nvme0n1", 200 * GiB))
    esp, boot, root = plan.volumes
    assert (esp.size_bytes, esp.grow) == (1 * GiB, False), "an ESP gains nothing from growing"
    assert (boot.size_bytes, boot.grow) == (2 * GiB, False)
    assert root.grow is True
    assert root.size_bytes > 190 * GiB
    assert root.size_bytes % ALIGN == 0, "partitions stay 1 MiB aligned"


def test_growing_uses_the_right_tool_per_filesystem():
    """ext* grows offline with resize2fs; xfs only grows MOUNTED, via xfs_growfs. Swapping them
    yields a restore that "succeeds" and never uses the extra space."""
    ext4 = plan_restore(_layout(ROOT_EXT4), Disk("sdb", 200 * GiB)).volumes[-1]
    xfs = plan_restore(_layout(ROOT_XFS), Disk("sdb", 200 * GiB)).volumes[-1]
    assert ext4.grow_command_kind == "resize2fs"
    assert xfs.grow_command_kind == "xfs_growfs"
    assert PlannedVolume(volume=ROOT_EXT4, size_bytes=1, grow=False).grow_command_kind == "none"


def test_a_smaller_target_is_fine_when_the_DATA_fits():
    """The whole point of used-block imaging: a 50 GB source holding 6 GB fits on 20 GB.

    Refusing on the source's DISK size instead would reject exactly the case this feature exists
    for.
    """
    plan = plan_restore(_layout(), Disk("sda", 20 * GiB))
    assert plan.volumes[-1].size_bytes < 20 * GiB
    assert plan.volumes[-1].grow is False
    assert any("smaller container" in n for n in plan.notes)


def test_a_target_too_small_for_the_data_is_refused():
    with pytest.raises(ImagingError) as exc:
        plan_restore(_layout(), Disk("sda", 4 * GiB))
    assert "bytes of data" in str(exc.value)


def test_shrinking_xfs_is_refused_rather_than_attempted():
    """The one genuinely impossible operation: xfs has no shrink. Better a clear error before
    anything is written than a half-restored disk."""
    with pytest.raises(ImagingError) as exc:
        plan_restore(_layout(ROOT_XFS), Disk("sda", 20 * GiB))
    assert "cannot be shrunk" in str(exc.value)


def test_a_non_growable_last_filesystem_is_left_alone_with_a_note():
    """vfat as the last volume: restore it as it was and say what is left unused, rather than
    silently pretending the disk is full."""
    layout = SourceLayout(
        disk_size=50 * GiB,
        volumes=(BOOT, Volume(role="data", fs_type="vfat", size_bytes=4 * GiB, used_bytes=1 * GiB)),
    )
    plan = plan_restore(layout, Disk("sdb", 100 * GiB))
    assert plan.volumes[-1].size_bytes == 4 * GiB
    assert plan.volumes[-1].grow is False
    assert any("cannot be grown" in n for n in plan.notes)


def test_gpt_leaves_room_for_the_backup_header():
    """GPT keeps a backup header + array at the very end; writing the last partition to the final
    byte corrupts it."""
    size = 100 * GiB
    gpt = plan_restore(_layout(), Disk("sdb", size))
    used = sum(v.size_bytes for v in gpt.volumes)
    assert used < size, "the tail must stay free"
    assert size - used >= 1024 * 1024


def test_lvm_directly_on_the_disk_is_recorded():
    """A real layout — this host's sdb has PVs straight on the device, no partition table."""
    plan = plan_restore(_layout(lvm_on_raw_disk=True), Disk("sdb", 100 * GiB))
    assert any("no partition table" in n for n in plan.notes)


def test_an_empty_layout_is_an_error():
    with pytest.raises(ImagingError):
        plan_restore(SourceLayout(disk_size=50 * GiB), Disk("sda", 100 * GiB))


def test_used_total_counts_data_not_containers():
    assert _layout().used_total == ESP.used_bytes + BOOT.used_bytes + ROOT_EXT4.used_bytes
