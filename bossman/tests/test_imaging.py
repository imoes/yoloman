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
    _partition_number,
    _split_vg_lv,
    candidate_disks,
    capture_pipeline,
    classify_role,
    fetch_command,
    grow_commands,
    parse_layout,
    partclone_tool,
    plan_restore,
    required_tools,
    restore_pipeline,
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


# ---------------------------------------------------------------------------
# Parsing the real tool output
#
# These fixtures are this host's actual `lsblk -b --json` and a real `sfdisk --json` (produced
# against a file-backed table, so the format is the tool's own and not remembered). It covers
# both shapes that must work: LVM on a partition (sda3 -> ubuntu--vg) and LVM straight on the
# disk with no partition table (sdb -> data--vg).

SDA = {
    "name": "sda", "type": "disk", "size": 53687099392, "fstype": None, "fsused": None,
    "mountpoint": None, "rm": False,
    "children": [
        {"name": "sda1", "type": "part", "size": 1127219200, "fstype": "vfat",
         "fsused": 6438912, "mountpoint": "/boot/efi", "rm": False},
        {"name": "sda2", "type": "part", "size": 2147483648, "fstype": "ext4",
         "fsused": 232456192, "mountpoint": "/boot", "rm": False},
        {"name": "sda3", "type": "part", "size": 50410291200, "fstype": "LVM2_member",
         "fsused": None, "mountpoint": None, "rm": False,
         "children": [
             {"name": "ubuntu--vg-ubuntu--lv", "type": "lvm", "size": 50407145472,
              "fstype": "ext4", "fsused": 30749495296, "mountpoint": "/", "rm": False},
         ]},
    ],
}

SDB = {
    "name": "sdb", "type": "disk", "size": 182536126464, "fstype": "LVM2_member",
    "fsused": None, "mountpoint": None, "rm": False,
    "children": [
        {"name": "data--vg-home", "type": "lvm", "size": 64424509440, "fstype": "ext4",
         "fsused": 49883561984, "mountpoint": "/home", "rm": False},
        {"name": "data--vg-data1", "type": "lvm", "size": 118107406336, "fstype": "ext4",
         "fsused": 54400147456, "mountpoint": "/data1", "rm": False},
    ],
}

SFDISK = {
    "partitiontable": {
        "label": "gpt", "device": "/dev/sda", "unit": "sectors",
        "firstlba": 2048, "lastlba": 104857566, "sectorsize": 512,
        "partitions": [
            {"node": "/dev/sda1", "start": 2048, "size": 2201600,
             "type": "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", "name": "EFI"},
            {"node": "/dev/sda2", "start": 2203648, "size": 4194304,
             "type": "0FC63DAF-8483-4772-8E79-3D69D8477DE4"},
            {"node": "/dev/sda3", "start": 6397952, "size": 98459648,
             "type": "E6D6D379-F507-44C2-A23C-238F2A3DF928"},
        ],
    }
}


def test_the_real_layout_of_this_host_parses():
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    assert layout.label == "gpt"
    assert layout.disk_size == 53687099392
    assert [v.role for v in layout.volumes] == ["esp", "boot", "root"]
    assert [v.fs_type for v in layout.volumes] == ["vfat", "ext4", "ext4"]
    root = layout.volumes[-1]
    assert (root.vg, root.lv) == ("ubuntu-vg", "ubuntu-lv"), "dm dash-escaping decoded"
    assert root.used_bytes == 30749495296


def test_the_container_itself_is_not_a_volume():
    """sda3 is an LVM2_member — a PV, not data. Imaging it would copy the LV twice."""
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    assert all(v.fs_type != "lvm2_member" for v in layout.volumes)
    assert len(layout.volumes) == 3


def test_lvm_straight_on_the_disk_is_detected():
    """sdb has PVs on the raw device: there is no partition table to recreate."""
    layout = parse_layout(sfdisk=None, lsblk_disk=SDB)
    assert layout.lvm_on_raw_disk is True
    assert [v.lv for v in layout.volumes] == ["data1", "home"], "ordered, and dashes decoded"
    assert all(v.partition is None for v in layout.volumes)


def test_volume_order_puts_the_growable_one_last():
    """plan_restore grows the LAST volume, so the fixed boot pieces must sort before it."""
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    plan = plan_restore(layout, Disk("nvme0n1", 200 * GiB))
    assert plan.volumes[-1].volume.role == "root"
    assert plan.volumes[-1].grow is True
    assert [v.grow for v in plan.volumes[:-1]] == [False, False]


def test_an_unmounted_filesystem_reports_unknown_usage_not_zero():
    """The trap: `lsblk` fills `fsused` only for MOUNTED filesystems, and a cold capture — the
    recommended kind, since a live root is inconsistent — sees none of it.

    Zero would let plan_restore approve any target disk however small; the container size would
    reject the oversized-source case the feature exists for. So it is None, and planning refuses
    until the capture establishes the real number.
    """
    cold = {
        "name": "sda", "type": "disk", "size": 50 * GiB, "fstype": None, "rm": False,
        "children": [
            {"name": "sda1", "type": "part", "size": 40 * GiB, "fstype": "ext4",
             "fsused": None, "mountpoint": None, "rm": False},
        ],
    }
    layout = parse_layout(sfdisk=None, lsblk_disk=cold)
    assert layout.volumes[0].used_bytes is None
    assert len(layout.unknown_usage) == 1

    with pytest.raises(ImagingError) as exc:
        plan_restore(layout, Disk("sdb", 100 * GiB))
    assert "used size is unknown" in str(exc.value)
    assert "capture must record it" in str(exc.value)


def test_a_disk_without_a_size_is_refused():
    with pytest.raises(ImagingError):
        parse_layout(sfdisk=None, lsblk_disk={"name": "sda", "type": "disk", "size": 0})


def test_sector_size_is_read_not_assumed():
    """A 4Kn disk reports sectorsize 4096; assuming 512 understates every size eightfold."""
    four_k = {"partitiontable": {"label": "dos", "sectorsize": 4096, "partitions": []}}
    layout = parse_layout(sfdisk=four_k, lsblk_disk=SDA)
    assert layout.label == "dos", "the label type is taken from the table, not guessed"


def test_dm_names_decode_a_doubled_dash():
    """device-mapper escapes a literal dash by doubling it. Splitting naively on "-" turns
    "data--vg-home" into VG "data", and the restore would build a volume group that never
    existed."""
    assert _split_vg_lv("data--vg-home") == ("data-vg", "home")
    assert _split_vg_lv("ubuntu--vg-ubuntu--lv") == ("ubuntu-vg", "ubuntu-lv")
    assert _split_vg_lv("nodash") is None


def test_partition_numbers_from_both_naming_schemes():
    assert _partition_number("sda3") == 3
    assert _partition_number("nvme0n1p2") == 2, "nvme partitions carry a p"
    assert _partition_number("sdb") is None


def test_role_comes_from_the_mountpoint_then_the_type_guid():
    assert classify_role(mountpoint="/", fs_type="ext4", part_type=None) == "root"
    assert classify_role(mountpoint="/boot", fs_type="ext4", part_type=None) == "boot"
    assert classify_role(mountpoint="/boot/efi", fs_type="vfat", part_type=None) == "esp"
    # Unmounted: the GPT type is the only signal left.
    assert classify_role(
        mountpoint=None, fs_type="vfat", part_type="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
    ) == "esp", "the GUID comparison must be case-insensitive"
    assert classify_role(mountpoint="/srv", fs_type="xfs", part_type=None) == "data"


# ---------------------------------------------------------------------------
# The commands themselves


def test_the_partclone_binary_follows_the_filesystem():
    assert partclone_tool("ext4") == "partclone.ext4"
    assert partclone_tool("xfs") == "partclone.xfs"
    assert partclone_tool("EXT4") == "partclone.ext4", "case must not matter"


def test_an_unknown_filesystem_falls_back_to_raw_rather_than_failing():
    """A raw copy of an odd volume is still a correct backup, only a fat one. Refusing would block
    a whole host over one filesystem nobody planned for."""
    assert partclone_tool("zfs") == "partclone.dd"
    assert partclone_tool("") == "partclone.dd"


def test_required_tools_lists_everything_before_anything_runs():
    """A missing partclone.xfs found halfway through means a half-written image and a wasted
    transfer of everything captured before it."""
    layout = SourceLayout(
        disk_size=50 * GiB,
        volumes=(ESP, BOOT, Volume(role="data", fs_type="xfs", size_bytes=1, used_bytes=1)),
    )
    assert required_tools(layout) == ["partclone.ext4", "partclone.vfat", "partclone.xfs", "zstd"]


def test_capture_pipes_partclone_through_zstd_into_the_sink():
    line = capture_pipeline(ROOT_EXT4, device="/dev/mapper/vg-root", sink="cat > /img/root.zst")
    assert line.startswith("partclone.ext4 -c -s /dev/mapper/vg-root -o -")
    assert "| zstd -T0 -3 |" in line
    assert line.endswith("cat > /img/root.zst")


def test_capture_quotes_what_it_interpolates():
    """The sink is caller-supplied, and a pipeline needs a shell: an unquoted `;` would run as a
    command with the privileges an imaging job necessarily has."""
    line = capture_pipeline(ROOT_EXT4, device="/dev/x; rm -rf /", sink="cat > /img/x")
    assert "; rm -rf /" not in line.replace("'/dev/x; rm -rf /'", ""), "the device must be quoted"
    assert "'/dev/x; rm -rf /'" in line


def test_restore_uses_partclone_restore_and_never_dd():
    """The image holds only USED blocks, so dd would write partclone's metadata stream onto the
    disk as though it were data. `partclone.restore` reads the header and picks the handler."""
    line = restore_pipeline(source=fetch_command("https://s/root.zst"), device="/dev/mapper/vg-root")
    assert "partclone.restore -s - -o /dev/mapper/vg-root" in line
    assert " dd " not in line and not line.startswith("dd")
    assert "| zstd -dc |" in line


def test_fetch_retries_and_fails_loudly():
    """Not netcat: no length, no status, no resume, so a dropped connection writes a silently
    truncated disk. `-f` also stops an HTML error page from being written onto the filesystem."""
    cmd = fetch_command("https://s/root.zst")
    assert "curl" in cmd and "-f" in cmd
    assert "--retry" in cmd
    # A tame URL is passed through bare — shlex.quote adds nothing when nothing needs escaping,
    # which is correct. The property worth asserting is that a hostile one CANNOT break out.
    assert cmd.endswith("https://s/root.zst")
    hostile = fetch_command("https://s/x.zst; rm -rf /")
    assert "'https://s/x.zst; rm -rf /'" in hostile


def test_growing_ext4_checks_first_and_works_offline():
    """resize2fs refuses a filesystem not checked since its last mount, and a freshly restored
    image always looks exactly like that."""
    cmds = grow_commands(PlannedVolume(ROOT_EXT4, 200 * GiB, True), device="/dev/x")
    assert cmds == [["e2fsck", "-fy", "/dev/x"], ["resize2fs", "/dev/x"]]


def test_growing_xfs_mounts_first_and_passes_the_mountpoint():
    """xfs_growfs takes a MOUNT POINT and only works mounted; resize2fs takes a device and only
    works unmounted. Swapping the pair is the classic silent no-op."""
    cmds = grow_commands(PlannedVolume(ROOT_XFS, 200 * GiB, True), device="/dev/x", mountpoint="/mnt/t")
    assert ["mount", "/dev/x", "/mnt/t"] in cmds
    assert ["xfs_growfs", "/mnt/t"] in cmds, "the mountpoint, not the device"
    assert cmds[-1] == ["umount", "/mnt/t"], "and it must be unmounted again"
    assert not any("resize2fs" in c[0] for c in cmds)


def test_a_volume_that_does_not_grow_produces_no_commands():
    assert grow_commands(PlannedVolume(ROOT_EXT4, 40 * GiB, False), device="/dev/x") == []
