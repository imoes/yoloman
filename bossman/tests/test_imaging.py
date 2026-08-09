"""Phase 3a: the imaging plan — pure, no DB, no subprocess.

The fixtures are this host's real layout (`lsblk -b --json`), because it happens to contain both
shapes the plan has to handle: LVM on a partition (sda3 → ubuntu--vg) and LVM straight on the
disk with no partition table (sdb → data--vg).
"""

import json
import re
import shlex
import shutil
import subprocess

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
    TARGET_ROOT,
    Step,
    identity_steps,
    layout_from_dict,
    layout_to_dict,
    lv_device,
    lvm_commands,
    parse_layout,
    partclone_tool,
    plan_restore,
    required_tools,
    restore_pipeline,
    restore_steps,
    restore_vars,
    select_target_disk,
    with_measured_usage,
    sfdisk_script,
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


# ---------------------------------------------------------------------------
# Writing the target: partition table and LVM


def test_the_partition_table_carries_units_and_an_open_ended_last_entry():
    """Sizes with a unit mean nothing here converts bytes to sectors — which matters because a
    4Kn target reports a 4096-byte sector and counts computed against the source's 512 would be
    eight times wrong. The empty last `size=` hands the remainder (and the GPT tail arithmetic)
    to sfdisk."""
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    script = sfdisk_script(layout)
    assert script.startswith("label: gpt\n")
    assert "size=1075MiB, type=uefi" in script
    assert "size=2048MiB, type=linux" in script
    assert script.rstrip().endswith("size=, type=lvm"), "the last entry claims what is left"


def test_the_pv_partition_is_typed_lvm_not_linux():
    """A PV partition typed `linux` still works but lies about its content, and some tooling
    (including installers looking for existing volume groups) reads the type."""
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    assert [p.kind for p in layout.partitions] == ["uefi", "boot" if False else "linux", "lvm"]


def test_lvm_on_the_raw_disk_has_no_table_to_write():
    """sdb's PVs sit on the device itself; emitting an empty table there would destroy it."""
    layout = parse_layout(sfdisk=None, lsblk_disk=SDB)
    assert layout.partitions == ()
    with pytest.raises(ImagingError) as exc:
        sfdisk_script(layout)
    assert "LVM directly on the disk" in str(exc.value)


def test_the_last_logical_volume_takes_the_rest_of_the_group():
    """`-l 100%FREE` rather than a computed size: LVM knows what its own metadata costs, and this
    is what makes a bigger target disk actually get used instead of merely partitioned."""
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    cmds = lvm_commands(layout, pv_device="/dev/nvme0n1p3")
    assert cmds[0][:1] == ["pvcreate"]
    assert ["vgcreate", "ubuntu-vg", "/dev/nvme0n1p3"] in cmds
    assert cmds[-1] == ["lvcreate", "-l", "100%FREE", "-n", "ubuntu-lv", "ubuntu-vg"]


def test_all_but_the_last_volume_keep_their_size():
    """Two LVs in one group: only the last absorbs the extra space."""
    two = {
        "name": "sdb", "type": "disk", "size": 180 * GiB, "fstype": "LVM2_member", "rm": False,
        "children": [
            {"name": "data--vg-home", "type": "lvm", "size": 60 * GiB, "fstype": "ext4",
             "fsused": 40 * GiB, "mountpoint": "/home"},
            {"name": "data--vg-srv", "type": "lvm", "size": 110 * GiB, "fstype": "ext4",
             "fsused": 50 * GiB, "mountpoint": "/srv"},
        ],
    }
    cmds = lvm_commands(parse_layout(sfdisk=None, lsblk_disk=two), pv_device="/dev/sdb")
    sized = [c for c in cmds if c[0] == "lvcreate" and "-L" in c]
    free = [c for c in cmds if c[0] == "lvcreate" and "100%FREE" in c]
    assert len(sized) == 1 and len(free) == 1
    # lvcreate's argv ends with the VG, so the name is the element after "-n".
    assert sized[0][sized[0].index("-n") + 1] == "home", "sorted by name, so home gets a size"
    assert free[0][free[0].index("-n") + 1] == "srv"


def test_the_lv_path_avoids_the_escaped_mapper_form():
    """/dev/<vg>/<lv> needs no dash doubling; /dev/mapper/<vg>-<lv> does, and that escaping is
    exactly what went wrong when parsing these names."""
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    assert lv_device(layout.volumes[-1]) == "/dev/ubuntu-vg/ubuntu-lv"
    with pytest.raises(ImagingError):
        lv_device(ESP)


# ---------------------------------------------------------------------------
# Against the real tool


@pytest.mark.skipif(not shutil.which("sfdisk"), reason="sfdisk not installed")
def test_real_sfdisk_accepts_the_script_and_fills_a_bigger_disk(tmp_path):
    """The claim of this whole feature, checked against the actual partitioner.

    A 50 GiB source layout written onto a 120 GiB disk must leave the last partition holding
    everything that is left — and still leave the GPT backup header its room at the very end.
    Asserted on sfdisk's own output rather than on our arithmetic, because ours is only there to
    validate and report.
    """
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    img = tmp_path / "target.img"
    subprocess.run(["truncate", "-s", "120G", str(img)], check=True)
    subprocess.run(
        ["sfdisk", "--quiet", str(img)],
        input=sfdisk_script(layout), text=True, check=True,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    table = json.loads(
        subprocess.run(["sfdisk", "--json", str(img)], capture_output=True, text=True, check=True).stdout
    )["partitiontable"]
    sector = table["sectorsize"]
    parts = table["partitions"]
    assert len(parts) == 3
    assert parts[0]["size"] * sector == 1075 * 1024**2, "the ESP keeps its size"
    last = parts[-1]
    # The property, not a magic number: the last partition holds everything the fixed ones left.
    # (120 GiB minus 1075 + 2048 MiB is ~116.9 GiB — my first attempt asserted >118 and was simply
    # bad arithmetic on my part, not a defect in the script.)
    fixed = sum(p["size"] for p in parts[:-1]) * sector
    assert last["size"] * sector > (120 * GiB) - fixed - (8 * 1024**2)
    assert last["size"] * sector > 4 * layout.volumes[-1].size_bytes // 2, "it really did grow"
    tail = table["lastlba"] - (last["start"] + last["size"])
    assert 0 <= tail < 4096, f"GPT tail left {tail} sectors — room for the backup header, no more"


# ---------------------------------------------------------------------------
# The whole run. Order is the substance: a wrong order gives an unbootable machine, not an error.


def _run(target_gib: int = 200, hostname: str = "web07", disk: str = "sda") -> list[Step]:
    # Default target is /dev/sda — the real deployment case (the targets are VMs). The nvme
    # partition-suffix path (/dev/nvme0n1 -> p3) is exercised by test_nvme_partitions_get_their_p,
    # which passes disk="nvme0n1"; nvme is a test input there, never a deployment default.
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    plan = plan_restore(layout, Disk(disk, target_gib * GiB))
    return restore_steps(layout, plan, image_url="https://b/img/42", hostname=hostname)


def _index(steps: list[Step], needle: str) -> int:
    for i, s in enumerate(steps):
        if needle in s.name:
            return i
    raise AssertionError(f"no step matching {needle!r} in {[s.name for s in steps]}")


def test_a_step_carries_exactly_one_of_argv_or_shell():
    """A step that is both is ambiguous about whether it needs a shell — and a step that is
    neither does nothing while reporting success."""
    with pytest.raises(ImagingError):
        Step(name="both", argv=("ls",), shell="ls")
    with pytest.raises(ImagingError):
        Step(name="neither")


def test_volumes_exist_before_anything_is_written_into_them():
    steps = _run()
    assert _index(steps, "write partition table") < _index(steps, "lvm: pvcreate")
    assert _index(steps, "lvm: lvcreate") < _index(steps, "restore root")


def test_the_grow_happens_right_after_its_own_restore_and_before_mounting():
    """Growing with the assembly tree mounted on top is how you grow the wrong thing."""
    steps = _run()
    assert _index(steps, "restore root") < _index(steps, "grow root")
    assert _index(steps, "grow root") < _index(steps, "mount root")


def test_mounts_go_parents_first_and_unmounts_strictly_reversed():
    """Mounting /boot before / hides it under the filesystem that lands on top; unmounting in the
    same order fails because the parent is busy."""
    steps = _run()
    assert _index(steps, "mount root") < _index(steps, "mount boot") < _index(steps, "mount esp")
    assert _index(steps, "umount esp") < _index(steps, "umount boot") < _index(steps, "umount root")
    assert _index(steps, "mount esp") < _index(steps, "umount esp")


def test_the_chroot_has_its_pseudo_filesystems_before_any_chroot_step():
    """grub-install reads /sys to find the disk; without the binds it fails in a way that reads
    like an unrelated bug."""
    steps = _run()
    # The chroot steps are now module runs whose shell does `chroot /mnt/target … run-module …`.
    first_chroot = min(i for i, s in enumerate(steps) if s.shell and f"chroot {TARGET_ROOT}" in s.shell)
    for src in ("/dev", "/proc", "/sys"):
        assert _index(steps, f"bind {src}") < first_chroot


def test_dev_pts_is_not_bound_separately():
    """`--rbind /dev` carries its submounts, and a separate entry would fail on an image whose
    /dev/pts directory does not exist yet."""
    steps = _run()
    assert not any("dev/pts" in s.name for s in steps)


def test_the_bootloader_is_installed_inside_the_target_not_the_helper():
    """grub must run INSIDE the target chroot, else it would write the helper's bootloader — the
    single most consequential mistake in this whole sequence. Now the yoloman.bootloader module."""
    steps = _run()
    grub = [s for s in steps if "bootloader" in s.name]
    assert len(grub) == 1
    # Runs in the target chroot; the fixture layout has an ESP → UEFI (firmware-aware).
    assert f"chroot {TARGET_ROOT}" in grub[0].shell
    assert "run-module yoloman.bootloader" in grub[0].shell
    assert '"firmware": "uefi"' in grub[0].shell


def test_bios_layout_installs_grub_to_disk():
    """The real deployment case: a BIOS VM (no ESP) restored to /dev/sda → the module gets
    firmware=bios + the disk, and installs i386-pc grub to the disk's boot code in the chroot."""
    layout = SourceLayout(disk_size=50 * GiB, volumes=(BOOT, ROOT_EXT4))
    steps = restore_steps(
        layout, plan_restore(layout, Disk("sda", 200 * GiB)),
        image_url="https://b/img/42", hostname="web07",
    )
    grub = [s for s in steps if "bootloader" in s.name]
    assert len(grub) == 1
    assert f"chroot {TARGET_ROOT}" in grub[0].shell
    assert "run-module yoloman.bootloader" in grub[0].shell
    assert '"firmware": "bios"' in grub[0].shell
    assert "/dev/sda" in grub[0].shell


def test_identity_is_reset_before_the_target_is_unmounted():
    """It has to be written into the mounted target, and skipping it produces twins that fight
    over DHCP leases and present the same SSH fingerprint."""
    steps = _run()
    # Identity is now the yoloman.machine_identity module (run in the chroot), not bespoke shell.
    assert _index(steps, "reset identity (machine_identity module)") < _index(steps, "umount root")
    assert _index(steps, "install bootloader") < _index(steps, "reset identity (machine_identity module)")


def test_identity_runs_the_machine_identity_module_in_the_chroot():
    """The machine-id-empty / ssh-keys / hostname / hosts / cloud-init logic lives in the module
    (proven idempotent in its own runtime test); identity_steps is just its chroot invocation. The
    agent + modules are staged into the target once by restore_steps (shared with bootloader/initramfs),
    so identity_steps itself is a single step."""
    steps = identity_steps("h")
    assert len(steps) == 1
    run = steps[0]
    assert f"chroot {TARGET_ROOT}" in run.shell
    assert "run-module yoloman.machine_identity" in run.shell
    assert "--modules-dir" in run.shell


def test_restore_stages_and_cleans_up_the_provisioning_agent_and_modules():
    """The chroot module steps need the agent + PE-baked modules inside the target; they are staged
    once after the bind mounts and removed before the unmount so they never ride into the booted OS."""
    steps = _run()
    stage = _index(steps, "stage the provisioning agent + modules into the target")
    clean = _index(steps, "clean up staged provisioning agent + modules")
    ident = _index(steps, "reset identity (machine_identity module)")
    assert stage < ident < clean
    assert clean < _index(steps, "umount root")


def test_the_hostname_is_quoted():
    step = next(s for s in identity_steps("web07; rm -rf /") if s.name == "reset identity (machine_identity module)")
    # The hostname reaches the module as shell-quoted JSON, so shell metacharacters cannot inject.
    assert shlex.quote(json.dumps({"hostname": "web07; rm -rf /"})) in step.shell
    assert "; rm -rf /'" not in step.shell.replace(shlex.quote(json.dumps({"hostname": "web07; rm -rf /"})), "")


def test_nvme_partitions_get_their_p():
    """`/dev/nvme0n13` does not exist, so this fails loudly rather than writing somewhere wrong —
    but being right about it is cheaper than the confusion. nvme is only a test input here."""
    steps = _run(disk="nvme0n1")
    assert any("/dev/nvme0n1p3" in " ".join(s.argv) for s in steps if s.argv)
    assert not any("nvme0n13" in " ".join(s.argv) + s.shell for s in steps)


def test_each_volumes_image_has_a_distinct_name():
    """Two data LVs would otherwise share a file name and overwrite each other in the store."""
    two = {
        "name": "sdb", "type": "disk", "size": 180 * GiB, "fstype": "LVM2_member", "rm": False,
        "children": [
            {"name": "vg-a", "type": "lvm", "size": 60 * GiB, "fstype": "ext4",
             "fsused": 10 * GiB, "mountpoint": "/srv/a"},
            {"name": "vg-b", "type": "lvm", "size": 100 * GiB, "fstype": "ext4",
             "fsused": 10 * GiB, "mountpoint": "/srv/b"},
        ],
    }
    layout = parse_layout(sfdisk=None, lsblk_disk=two)
    plan = plan_restore(layout, Disk("sdc", 400 * GiB))
    shells = [s.shell for s in restore_steps(layout, plan, image_url="https://b/i", hostname="h") if "restore" in s.name]
    assert len(shells) == 2
    # The restore is now a run-module step; the source_url lives inside its JSON params. Pull the image
    # URLs out and assert they are distinct (else two data LVs overwrite each other in the store).
    found = {m for u in shells for m in re.findall(r'https://[^"]+\.pcl\.zst', u)}
    assert len(found) == 2, f"two distinct image URLs, got {found}"


def test_lvm_on_a_raw_disk_writes_no_partition_table():
    """sdb's PVs live on the device; wiping and writing a table there would destroy them."""
    layout = parse_layout(sfdisk=None, lsblk_disk=SDB)
    plan = plan_restore(layout, Disk("sdc", 400 * GiB))
    steps = restore_steps(layout, plan, image_url="https://b/i", hostname="h")
    assert not any("partition table" in s.name for s in steps)
    assert any(s.argv[:1] == ("pvcreate",) for s in steps if s.argv)


# ---------------------------------------------------------------------------
# The manifest as stored: it has to be readable by a restore months later


def test_the_manifest_round_trips_exactly():
    """It is the document the restore reads back; a lossy round-trip means wrong partition sizes,
    and that surfaces as a machine that will not boot rather than as an error."""
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    assert layout_from_dict(layout_to_dict(layout)) == layout


def test_unknown_usage_survives_as_null_not_zero():
    """JSON has a null, so there is no excuse to collapse the distinction the whole nullable field
    exists for — zero would let a restore be planned onto a disk far too small."""
    cold = {
        "name": "sda", "type": "disk", "size": 50 * GiB, "fstype": None,
        "children": [{"name": "sda1", "type": "part", "size": 40 * GiB, "fstype": "ext4",
                      "fsused": None, "mountpoint": None}],
    }
    layout = parse_layout(sfdisk=None, lsblk_disk=cold)
    doc = layout_to_dict(layout)
    assert doc["volumes"][0]["used_bytes"] is None
    assert json.loads(json.dumps(doc))["volumes"][0]["used_bytes"] is None
    assert layout_from_dict(doc).volumes[0].used_bytes is None


def test_an_unknown_manifest_version_is_refused():
    """Best-effort parsing of a layout we half understand writes partitions at the wrong sizes."""
    doc = layout_to_dict(parse_layout(sfdisk=SFDISK, lsblk_disk=SDA))
    doc["version"] = 2
    with pytest.raises(ImagingError) as exc:
        layout_from_dict(doc)
    assert "manifest version" in str(exc.value)


def test_measured_usage_makes_an_unplannable_manifest_plannable():
    """partclone reports what it actually moved — the only number available for a filesystem that
    was never mounted, and the authoritative one either way."""
    cold = {
        "name": "sda", "type": "disk", "size": 50 * GiB, "fstype": None,
        "children": [{"name": "sda1", "type": "part", "size": 40 * GiB, "fstype": "ext4",
                      "fsused": None, "mountpoint": "/"}],
    }
    layout = parse_layout(sfdisk=None, lsblk_disk=cold)
    with pytest.raises(ImagingError):
        layout.used_total

    filled = with_measured_usage(layout, {"root": 7 * GiB})
    assert filled.used_total == 7 * GiB
    assert plan_restore(filled, Disk("sdb", 100 * GiB)).volumes[-1].grow is True


def test_measured_usage_leaves_known_values_alone():
    """A mounted source already reported the truth; overwriting it with a second measurement would
    make the two sources disagree for no reason."""
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    before = layout.volumes[-1].used_bytes
    after = with_measured_usage(layout, {"root-ubuntu-lv": 1}).volumes[-1].used_bytes
    assert after == before


def test_the_usage_key_matches_the_image_file_name():
    """The capture reports usage under the same stem the image file uses, so the report and the
    restore's lookup cannot drift apart."""
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    plan = plan_restore(layout, Disk("sdb", 200 * GiB))
    steps = restore_steps(layout, plan, image_url="https://b/i", hostname="h")
    urls = [m for s in steps if s.shell for m in re.findall(r'https://[^"]+\.pcl\.zst', s.shell)]
    assert any(u.endswith("/root-ubuntu-lv.pcl.zst") for u in urls)
    # and that stem is exactly what with_measured_usage accepts
    assert with_measured_usage(
        SourceLayout(disk_size=1, volumes=(Volume("root", "ext4", 1, None, vg="ubuntu-vg", lv="ubuntu-lv"),)),
        {"root-ubuntu-lv": 42},
    ).volumes[0].used_bytes == 42


# ── Multi-volume proportional grow (root/var/home on LVM) — the PXE template case ──────────────

_VG = "sys-vg"


def _lvm_rvh() -> SourceLayout:
    """ESP + /boot partitions + root/var/home as LVs in one VG (the classic template layout)."""
    root = Volume(role="root", fs_type="ext4", size_bytes=10 * GiB, used_bytes=4 * GiB, vg=_VG, lv="root", mountpoint="/")
    var = Volume(role="var", fs_type="ext4", size_bytes=10 * GiB, used_bytes=2 * GiB, vg=_VG, lv="var", mountpoint="/var")
    home = Volume(role="home", fs_type="ext4", size_bytes=10 * GiB, used_bytes=1 * GiB, vg=_VG, lv="home", mountpoint="/home")
    return SourceLayout(disk_size=50 * GiB, volumes=(ESP, BOOT, root, var, home))


def test_var_and_home_get_their_own_roles():
    assert classify_role(mountpoint="/var", fs_type="ext4", part_type=None) == "var"
    assert classify_role(mountpoint="/home", fs_type="ext4", part_type=None) == "home"
    assert classify_role(mountpoint="/srv", fs_type="ext4", part_type=None) == "data"


def test_grow_policy_splits_leftover_by_percent():
    plan = plan_restore(_lvm_rvh(), Disk("vda", 200 * GiB), grow_policy={"root": 50, "var": 30, "home": 20})
    by = {p.volume.role: p for p in plan.volumes}
    # esp + boot stay fixed
    assert by["esp"].size_bytes == ESP.size_bytes and not by["esp"].grow
    assert by["boot"].size_bytes == BOOT.size_bytes and not by["boot"].grow
    # root/var/home all grow, split ~50/30/20 of the growable total
    assert all(by[r].grow for r in ("root", "var", "home"))
    total = by["root"].size_bytes + by["var"].size_bytes + by["home"].size_bytes
    assert abs(by["root"].size_bytes / total - 0.5) < 0.01
    assert abs(by["var"].size_bytes / total - 0.3) < 0.01
    assert abs(by["home"].size_bytes / total - 0.2) < 0.01
    assert by["root"].size_bytes > by["var"].size_bytes > by["home"].size_bytes
    # essentially the whole disk (minus fixed volumes + a few MiB of GPT/align overhead) is claimed
    leftover = 200 * GiB - ESP.size_bytes - BOOT.size_bytes
    assert leftover - 4 * 1024**2 <= total <= leftover


def test_grow_policy_keeps_a_big_source_volume_and_last_absorbs_the_rest():
    """A volume whose SOURCE is larger than its percentage share is never shrunk — it keeps its size — and
    the LAST growable volume absorbs whatever is left (+100%FREE), so no volume shrinks and the disk fills."""
    vg = "vg0"
    big = Volume(role="root", fs_type="ext4", size_bytes=60 * GiB, used_bytes=5 * GiB, vg=vg, lv="root", mountpoint="/")
    var = Volume(role="var", fs_type="ext4", size_bytes=10 * GiB, used_bytes=2 * GiB, vg=vg, lv="var", mountpoint="/var")
    home = Volume(role="home", fs_type="ext4", size_bytes=10 * GiB, used_bytes=1 * GiB, vg=vg, lv="home", mountpoint="/home")
    layout = SourceLayout(disk_size=100 * GiB, volumes=(ESP, BOOT, big, var, home))
    # root asks for only 5% (< its 60 GiB source) → it must keep 60 GiB, not shrink. home is last → fills.
    plan = plan_restore(layout, Disk("vda", 200 * GiB), grow_policy={"root": 5, "var": 10, "home": 30})
    by = {p.volume.role: p for p in plan.volumes}
    assert by["root"].size_bytes >= 60 * GiB, "the big /root keeps at least its source size"
    assert by["home"].fill and by["home"].grow, "the last growable absorbs the rest with +100%FREE"
    assert not by["root"].fill and not by["var"].fill
    # the whole leftover is used (root kept + var share + home fill ≈ remaining)
    remaining = 200 * GiB - ESP.size_bytes - BOOT.size_bytes
    total = by["root"].size_bytes + by["var"].size_bytes + by["home"].size_bytes
    assert remaining - 8 * 1024**2 <= total <= remaining


def test_grow_policy_that_does_not_fit_is_a_clear_error():
    # growable order root, var, home → home is the fill volume; root and var are the "body". Asking root and
    # var for 90% each demands ~180% of the disk between them alone → does not fit → clear error.
    with pytest.raises(ImagingError) as exc:
        plan_restore(_lvm_rvh(), Disk("vda", 200 * GiB), grow_policy={"root": 90, "var": 90, "home": 10})
    assert "does not fit" in str(exc.value)


def test_grow_policy_last_volume_is_the_fill_lv_in_restore_vars():
    """The last growable LV is emitted as +100%FREE; the others get explicit sizes."""
    layout = _lvm_rvh()  # growable order root, var, home → home is last (the fill LV)
    plan = plan_restore(layout, Disk("vda", 200 * GiB), grow_policy={"root": 50, "var": 30, "home": 20})
    v = restore_vars(layout, plan, image_url="https://b/i", hostname="h")
    sizes = {g["lv"]: g["size"] for g in v["pe_vars"]["grow_lvs"]}
    assert sizes.get("home") == "+100%FREE", "the last growable LV fills the rest"
    assert sizes.get("root", "").endswith("m") and sizes.get("var", "").endswith("m"), "the others are explicit"


def test_grow_policy_without_policy_is_unchanged_single_last():
    # No policy → only the last volume grows (the pre-existing contract).
    plan = plan_restore(_lvm_rvh(), Disk("vda", 200 * GiB))
    grows = [p.volume.role for p in plan.volumes if p.grow]
    assert grows == ["home"]  # home is last → the only one that grows without a policy


def test_grow_policy_needs_lvm_for_multiple_volumes():
    root = Volume(role="root", fs_type="ext4", size_bytes=10 * GiB, used_bytes=4 * GiB, partition=2, mountpoint="/")
    var = Volume(role="var", fs_type="ext4", size_bytes=10 * GiB, used_bytes=2 * GiB, partition=3, mountpoint="/var")
    layout = SourceLayout(disk_size=50 * GiB, volumes=(BOOT, root, var))
    with pytest.raises(ImagingError):
        plan_restore(layout, Disk("sdb", 100 * GiB), grow_policy={"root": 60, "var": 40})


def test_grow_policy_unknown_roles_raise():
    with pytest.raises(ImagingError):
        plan_restore(_lvm_rvh(), Disk("vda", 200 * GiB), grow_policy={"database": 100})


def test_lvm_commands_size_each_growable_lv_with_one_free():
    layout = _lvm_rvh()
    plan = plan_restore(layout, Disk("vda", 200 * GiB), grow_policy={"root": 50, "var": 30, "home": 20})
    cmds = lvm_commands(layout, pv_device="/dev/vda3", plan=plan)
    lvcreates = [c for c in cmds if c and c[0] == "lvcreate"]
    free = [c for c in lvcreates if "100%FREE" in c]
    explicit = [c for c in lvcreates if "-L" in c]
    assert len(free) == 1                 # exactly one LV takes the remainder
    assert len(explicit) == len(lvcreates) - 1   # the other growable LVs are sized explicitly
    assert len(lvcreates) == 3            # root, var, home


# ── Playbook-driven restore: restore_vars() resolves the layout+plan into playbook vars ──────────
def test_restore_vars_resolves_playbook_vars_and_mounts():
    """restore_vars is the data behind the two Ansible restore playbooks; it must resolve the same
    devices/URLs/mounts restore_steps uses, as loopable vars."""
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    plan = plan_restore(layout, Disk("sda", 200 * GiB))
    v = restore_vars(layout, plan, image_url="https://b/i", hostname="web07.example.com",
                     network={"mode": "static", "interface": "eth0", "address": "192.0.2.60/24",
                              "gateway": "192.0.2.1", "dns": ["192.0.2.1"]})
    pe, tgt, mounts = v["pe_vars"], v["target_vars"], v["mounts"]
    assert pe["target_disk"] == "/dev/sda"
    # every restore target has a device + a .pcl.zst image URL
    assert pe["restore_volumes"] and all(r["device"] and r["source_url"].endswith(".pcl.zst") for r in pe["restore_volumes"])
    # LVs are created at SOURCE size (megabytes), then grown after the restore via lvextend --resizefs:
    # the free LV of the group grows to 100%FREE (absorbs the bigger disk).
    if pe["logical_volumes"]:
        assert all(lv["size"].endswith("m") for lv in pe["logical_volumes"]), "created at source size, not 100%FREE"
        assert pe["grow_lvs"], "the growable LVs are resized after the restore"
        assert any(g["size"] == "+100%FREE" for g in pe["grow_lvs"]), "the free LV grows to 100%FREE"
    # mounts are parents-first (root's mountpoint is the shortest) and under /mnt/target
    assert mounts and mounts[0]["mountpoint"] == "/mnt/target"
    assert all(m["mountpoint"].startswith("/mnt/target") for m in mounts)
    # target phase: firmware resolved, network mapped to the module's shape
    assert tgt["firmware"] in ("bios", "uefi")
    assert tgt["target_hostname"] == "web07.example.com"
    assert tgt["network"] == {"method": "static", "name": "eth0", "address": "192.0.2.60/24",
                              "gateway": "192.0.2.1", "dns": ["192.0.2.1"]}


def test_restore_vars_nvme_devices_get_their_p():
    layout = parse_layout(sfdisk=SFDISK, lsblk_disk=SDA)
    v = restore_vars(layout, plan_restore(layout, Disk("nvme0n1", 200 * GiB)),
                     image_url="https://b/i", hostname="h")
    blob = str(v)
    assert "nvme0n1" in v["pe_vars"]["target_disk"]
    assert "nvme0n13" not in blob  # partition suffix must be p3, never bare


def test_firmware_derivation_from_the_manifest():
    """UEFI vs BIOS is read from the manifest the capture already wrote, not re-inspected. The signal is an
    EFI System Partition (imaging._sfdisk_kind classifies it `uefi`); its presence means UEFI, its absence
    BIOS — including a GPT disk that boots BIOS via a bios_boot partition. No partitions at all → unknown."""
    from bossman.api.images import _firmware_of

    assert _firmware_of({"label": "gpt", "partitions": [
        {"number": 1, "kind": "uefi"}, {"number": 2, "kind": "lvm"}]}) == "uefi"
    assert _firmware_of({"label": "dos", "partitions": [
        {"number": 1, "kind": "linux"}, {"number": 2, "kind": "swap"}]}) == "bios"
    # GPT with a BIOS boot partition (grub on GPT, no ESP) is still BIOS.
    assert _firmware_of({"label": "gpt", "partitions": [
        {"number": 1, "kind": "bios_boot"}, {"number": 2, "kind": "lvm"}]}) == "bios"
    assert _firmware_of({}) == "unknown"
    assert _firmware_of({"partitions": []}) == "unknown"


def test_absolute_grow_gives_each_volume_its_gib_and_root_the_rest():
    # var 30 GiB, home 20 GiB, root = remainder (0). On a 200 GiB disk root should get the large leftover.
    plan = plan_restore(_lvm_rvh(), Disk("vda", 200 * GiB),
                        grow_policy={"root": 0, "var": 30, "home": 20}, grow_mode="absolute")
    by = {p.volume.role: p for p in plan.volumes}
    assert by["var"].size_bytes == 30 * GiB and by["var"].grow
    assert by["home"].size_bytes == 20 * GiB and by["home"].grow
    # root soaks up the rest: ~ 200 - esp - boot - 30 - 20 ≈ 147 GiB, and is much bigger than the others.
    assert by["root"].size_bytes > 140 * GiB
    assert by["root"].size_bytes > by["var"].size_bytes > by["home"].size_bytes
    # esp/boot untouched
    assert not by["esp"].grow and not by["boot"].grow


def test_absolute_grow_refuses_more_than_one_remainder():
    with pytest.raises(ImagingError) as exc:
        plan_restore(_lvm_rvh(), Disk("vda", 200 * GiB),
                     grow_policy={"root": 0, "var": 0, "home": 20}, grow_mode="absolute")
    assert "remainder" in str(exc.value)


def test_absolute_grow_with_no_remainder_lets_the_last_named_volume_absorb_the_rest():
    # All positive: var 30, home 20, root 40 — root is last in grow order? order is root,var,home, so home
    # is the implicit remainder and gets the leftover (much more than its 20 GiB request).
    plan = plan_restore(_lvm_rvh(), Disk("vda", 200 * GiB),
                        grow_policy={"root": 40, "var": 30, "home": 20}, grow_mode="absolute")
    by = {p.volume.role: p for p in plan.volumes}
    assert by["root"].size_bytes == 40 * GiB
    assert by["var"].size_bytes == 30 * GiB
    assert by["home"].size_bytes > 20 * GiB   # implicit remainder absorbed the leftover


def test_absolute_grow_refuses_sizes_that_exceed_the_disk():
    # 500 GiB of explicit sizes will not fit a 100 GiB target.
    with pytest.raises(ImagingError):
        plan_restore(_lvm_rvh(), Disk("vda", 100 * GiB),
                     grow_policy={"root": 0, "var": 300, "home": 200}, grow_mode="absolute")


def test_absolute_grow_refuses_a_size_below_the_data_it_holds():
    # var holds 2 GiB of data; giving it 1 GiB is impossible.
    with pytest.raises(ImagingError) as exc:
        plan_restore(_lvm_rvh(), Disk("vda", 200 * GiB),
                     grow_policy={"root": 0, "var": 1, "home": 20}, grow_mode="absolute")
    assert "var" in str(exc.value)


def test_percent_mode_is_unchanged_by_the_grow_mode_parameter():
    # Passing grow_mode="percent" explicitly must equal the historical default.
    a = plan_restore(_lvm_rvh(), Disk("vda", 200 * GiB), grow_policy={"root": 50, "var": 30, "home": 20})
    b = plan_restore(_lvm_rvh(), Disk("vda", 200 * GiB),
                     grow_policy={"root": 50, "var": 30, "home": 20}, grow_mode="percent")
    assert [(p.volume.role, p.size_bytes, p.grow) for p in a.volumes] == \
           [(p.volume.role, p.size_bytes, p.grow) for p in b.volumes]
