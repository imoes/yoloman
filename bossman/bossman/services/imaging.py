"""Bare-metal imaging: capture a host's disk layout, restore it onto a different disk.

The goal is a thin, compressed image that lands on a target whose disk is usually a
*different size* — normally bigger — and ends up filling it. Two decisions from the plan shape
everything here:

**No shrinking.** XFS cannot be shrunk at all (only `xfs_growfs` exists), so "shrink to the
smallest partition, dd, grow again" is impossible for half of the estate. Instead only the
**used blocks** are imaged (`partclone` reads the filesystem's allocation map), restored into a
full-size partition, and grown afterwards. That reaches the same outcome for ext4 *and* xfs and
removes the riskiest offline step from the chain.

**Sizes in bytes, never in the human form.** `lsblk`'s `SIZE` is locale-formatted — on this host
it reads "46,9G", with a decimal comma. Anything parsing that is one locale away from computing
a wrong disk size, so every function here takes and returns exact byte counts (`lsblk -b`).

This module is deliberately pure: no subprocess, no DB, no agent. It turns captured facts into a
plan, which is the part worth unit-testing, and leaves execution to the caller.
"""

from __future__ import annotations

import shlex
from dataclasses import dataclass, field
from typing import Any

# Partitions are aligned to 1 MiB, as every current partitioner does: it keeps partitions on
# erase-block/stripe boundaries, and misalignment costs real write performance on SSDs and RAID.
ALIGN = 1024 * 1024

# GPT keeps a backup header + partition array at the very end of the disk. 1 MiB is far more
# than the 33 sectors actually required, and leaving a whole MiB keeps the arithmetic aligned.
GPT_TAIL_RESERVE = 1024 * 1024

# Filesystems we can image and grow. ext4 shrinks too, but we never need to (see the docstring);
# xfs can only grow, which is precisely why the used-block approach is the one that works for
# both.
GROWABLE = {"ext2", "ext3", "ext4", "xfs"}


class ImagingError(ValueError):
    """A layout that cannot be captured or a target that cannot receive it."""


@dataclass(frozen=True)
class Disk:
    """A candidate target disk, as reported by `lsblk -b --json`."""

    name: str
    size: int
    removable: bool = False


def candidate_disks(blockdevices: list[dict[str, Any]]) -> list[Disk]:
    """The disks a restore may legitimately target, largest first.

    Only `type == "disk"` and non-removable: `loop` devices (this host has eight, from snaps),
    `rom`, and USB sticks are never install targets — and a removable device is very often the
    medium the operator booted from.
    """
    out = [
        Disk(name=str(d.get("name") or ""), size=int(d.get("size") or 0), removable=bool(d.get("rm")))
        for d in blockdevices or []
        if d.get("type") == "disk"
    ]
    usable = [d for d in out if d.name and d.size > 0 and not d.removable]
    # Largest first, then by name so the order is total and reproducible — an install must not
    # depend on kernel enumeration order.
    return sorted(usable, key=lambda d: (-d.size, d.name))


def select_target_disk(blockdevices: list[dict[str, Any]], *, prefer: str | None = None) -> Disk:
    """Pick the disk to install onto, or raise.

    `prefer` (an explicit operator choice) wins if it is a real candidate. Otherwise the largest
    disk is taken — deliberately NOT "sda": on any NVMe machine the first disk is `nvme0n1`, and
    a hardcoded `sda` there either fails or, far worse, overwrites the wrong device. Enumeration
    is the only thing that survives contact with real hardware.
    """
    disks = candidate_disks(blockdevices)
    if not disks:
        raise ImagingError("no usable target disk found (all devices are removable, loop or rom)")
    if prefer:
        for d in disks:
            if d.name == prefer:
                return d
        raise ImagingError(
            f"requested target disk {prefer!r} is not a usable disk; candidates: "
            + ", ".join(d.name for d in disks)
        )
    return disks[0]


@dataclass(frozen=True)
class Volume:
    """One filesystem in the image: where it came from and how big its data actually is.

    `used_bytes` is what partclone will move; `size_bytes` is the container it came out of. The
    two differ by exactly the free space that never enters the image.

    `used_bytes` is **None until it is known**, and that distinction carries weight. `lsblk`
    reports `fsused` only for MOUNTED filesystems, so a cold capture — which is the recommended
    way, since a live root is inconsistent — sees nothing. Treating unknown as 0 would make
    `plan_restore` approve any target disk, however small; treating it as the full container
    would reject exactly the oversized-source case this feature exists for. So it stays None and
    `plan_restore` refuses to plan until the capture has filled it in (partclone counts the used
    blocks as it works, which is the authoritative number anyway).
    """

    role: str  # "esp" | "boot" | "root" | "data" | ...
    fs_type: str
    size_bytes: int
    used_bytes: int | None
    # Set when the filesystem lives on an LV rather than straight on a partition.
    vg: str | None = None
    lv: str | None = None
    # Partition number on the source disk (None for an LV).
    partition: int | None = None
    mountpoint: str | None = None


@dataclass(frozen=True)
class Partition:
    """A partition of the source disk, as it must be recreated on the target.

    Kept separately from `Volume` because the two are not the same thing and conflating them
    loses information: a partition holding an LVM PV has no filesystem of its own, and the
    partition table cannot be written from a list of filesystems alone. (Found by trying to
    write it — the first version of this module only recorded volumes.)

    `kind` is an sfdisk type ALIAS (`uefi`, `linux`, `lvm`, `swap`) rather than a GUID: sfdisk
    accepts both, and the alias is legible in a script a human may have to read at 3am.
    """

    number: int
    size_bytes: int
    kind: str  # uefi | linux | lvm | swap | bios_boot


@dataclass(frozen=True)
class SourceLayout:
    """The captured shape of a source disk — the manifest that travels with the image."""

    disk_size: int
    label: str = "gpt"  # gpt | dos
    partitions: tuple[Partition, ...] = ()
    volumes: tuple[Volume, ...] = ()
    # True when LVM sits directly on the disk with no partition table, which is a real layout:
    # this very host has it on sdb (`data--vg` PVs straight on the device).
    lvm_on_raw_disk: bool = False

    @property
    def unknown_usage(self) -> tuple[Volume, ...]:
        """Volumes whose used size the capture has not established yet."""
        return tuple(v for v in self.volumes if v.used_bytes is None)

    @property
    def used_total(self) -> int:
        if self.unknown_usage:
            raise ImagingError(
                "used size is unknown for: "
                + ", ".join(v.role for v in self.unknown_usage)
                + " — the capture must record it before a restore can be planned"
            )
        return sum(int(v.used_bytes or 0) for v in self.volumes)


@dataclass(frozen=True)
class PlannedVolume:
    """One volume as it will exist on the target: same data, possibly a bigger container."""

    volume: Volume
    size_bytes: int
    grow: bool  # whether the filesystem has to be extended after the restore

    @property
    def grow_command_kind(self) -> str:
        """Which tool grows this filesystem — they are genuinely different operations.

        ext* grows offline with resize2fs; xfs can only be grown while MOUNTED, via xfs_growfs.
        Getting that backwards is a common way to produce a restore that "succeeds" and leaves a
        filesystem that never uses the extra space.
        """
        if not self.grow:
            return "none"
        return "xfs_growfs" if self.volume.fs_type == "xfs" else "resize2fs"


@dataclass
class RestorePlan:
    target_disk: str
    target_size: int
    volumes: list[PlannedVolume] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def grows(self) -> list[PlannedVolume]:
        return [v for v in self.volumes if v.grow]


# GPT partition type GUIDs worth recognising. The type is more trustworthy than a size guess,
# and for an unmounted disk it is the only signal available.
_GPT_ESP = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
_GPT_LVM = "E6D6D379-F507-44C2-A23C-238F2A3DF928"
_GPT_SWAP = "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"
_GPT_BIOS_BOOT = "21686148-6449-6E6F-744E-656564454649"

# Filesystems that are containers or otherwise never imaged as data.
_NOT_A_FILESYSTEM = {"", "lvm2_member", "swap", "crypto_luks"}


def classify_role(*, mountpoint: str | None, fs_type: str, part_type: str | None) -> str:
    """What this volume is for, from the strongest signal available.

    The mountpoint is decisive when there is one; otherwise the GPT type GUID answers for the two
    that matter (ESP, BIOS boot). Everything else is data — a deliberately dull default, because
    guessing "this is probably root" from a size would be wrong on any host with a big /var.
    """
    mp = (mountpoint or "").rstrip("/") or ("/" if mountpoint == "/" else "")
    if mp == "/":
        return "root"
    if mp == "/boot":
        return "boot"
    if mp in ("/boot/efi", "/efi"):
        return "esp"
    upper = (part_type or "").upper()
    if upper == _GPT_ESP or fs_type.lower() == "vfat" and mp.startswith("/boot"):
        return "esp"
    if upper == _GPT_BIOS_BOOT:
        return "bios_boot"
    if upper == _GPT_SWAP or fs_type.lower() == "swap":
        return "swap"
    return "data"


def parse_layout(*, sfdisk: dict[str, Any] | None, lsblk_disk: dict[str, Any]) -> SourceLayout:
    """Build a manifest from the real output of `sfdisk --json` and `lsblk -b --json`.

    Both are needed and neither is redundant: `lsblk` knows the filesystems, their used size and
    the LVM tree; `sfdisk` knows the partition geometry and the label type, which is what has to
    be recreated on the target.

    Two facts about the inputs that are easy to get wrong:

    * `sfdisk` reports `start`/`size` in **sectors**, and `sectorsize` is not always 512 — a 4Kn
      disk reports 4096, so multiplying by a hardcoded 512 understates every size eightfold.
    * `lvs`/`lsblk` warnings go to stderr, but LVM also writes some errors to **stdout**; merging
      the two streams corrupts the JSON. Callers must capture stdout alone.
    """
    label = "gpt"
    sector = 512
    part_types: dict[str, str] = {}
    if sfdisk:
        table = sfdisk.get("partitiontable") or {}
        label = str(table.get("label") or "gpt")
        sector = int(table.get("sectorsize") or 512)
        for p in table.get("partitions") or []:
            node = str(p.get("node") or "")
            if node:
                part_types[node.rsplit("/", 1)[-1]] = str(p.get("type") or "")

    disk_size = int(lsblk_disk.get("size") or 0)
    if disk_size <= 0:
        raise ImagingError(f"disk {lsblk_disk.get('name')!r} reports no size")

    volumes: list[Volume] = []
    partitions: list[Partition] = []
    # LVM directly on the disk: the disk itself is the PV, so there is no partition table to
    # recreate. A real layout — this host's sdb is exactly that.
    lvm_on_raw = str(lsblk_disk.get("fstype") or "").lower() == "lvm2_member"

    def visit(node: dict[str, Any], partition: int | None, vg_lv: tuple[str, str] | None) -> None:
        fs = str(node.get("fstype") or "").lower()
        name = str(node.get("name") or "")
        kind = str(node.get("type") or "")

        if kind == "part":
            partition = _partition_number(name)
            if partition is not None:
                partitions.append(
                    Partition(
                        number=partition,
                        size_bytes=int(node.get("size") or 0),
                        kind=_sfdisk_kind(
                            fs_type=fs,
                            part_type=part_types.get(name),
                            mountpoint=node.get("mountpoint"),
                        ),
                    )
                )
        if kind == "lvm":
            vg_lv = _split_vg_lv(name)

        if fs and fs not in _NOT_A_FILESYSTEM:
            used = node.get("fsused")
            volumes.append(
                Volume(
                    role=classify_role(
                        mountpoint=node.get("mountpoint"),
                        fs_type=fs,
                        part_type=part_types.get(name),
                    ),
                    fs_type=fs,
                    size_bytes=int(node.get("size") or 0),
                    # None, not 0: see Volume's docstring — an unmounted filesystem reports
                    # nothing here and the capture has to establish it.
                    used_bytes=int(used) if used not in (None, "") else None,
                    vg=vg_lv[0] if vg_lv else None,
                    lv=vg_lv[1] if vg_lv else None,
                    partition=partition,
                    mountpoint=node.get("mountpoint") or None,
                )
            )
        for child in node.get("children") or []:
            visit(child, partition, vg_lv)

    for child in lsblk_disk.get("children") or []:
        visit(child, None, None)

    # Order matters downstream: plan_restore grows the LAST volume, so root/data must come last
    # and the fixed-size boot pieces first. Sorting by the source's own on-disk order is the only
    # thing that reproduces the original layout.
    volumes.sort(key=lambda v: (v.partition if v.partition is not None else 1 << 30, v.lv or ""))
    partitions.sort(key=lambda p: p.number)
    return SourceLayout(
        disk_size=disk_size,
        label=label,
        partitions=tuple(partitions),
        volumes=tuple(volumes),
        lvm_on_raw_disk=lvm_on_raw,
    )


def _sfdisk_kind(*, fs_type: str, part_type: str | None, mountpoint: str | None) -> str:
    """The sfdisk type alias for a partition we are about to recreate."""
    if fs_type == "lvm2_member":
        return "lvm"
    upper = (part_type or "").upper()
    if upper == _GPT_ESP:
        return "uefi"
    if upper == _GPT_BIOS_BOOT:
        return "bios_boot"
    if upper == _GPT_SWAP or fs_type == "swap":
        return "swap"
    if (mountpoint or "") in ("/boot/efi", "/efi") or fs_type == "vfat":
        return "uefi"
    return "linux"


def _partition_number(name: str) -> int | None:
    """"sda3" → 3, "nvme0n1p2" → 2. None when the name carries no partition index."""
    digits = ""
    for ch in reversed(name):
        if ch.isdigit():
            digits = ch + digits
        else:
            break
    return int(digits) if digits else None


def _split_vg_lv(name: str) -> tuple[str, str] | None:
    """"ubuntu--vg-ubuntu--lv" → ("ubuntu-vg", "ubuntu-lv").

    device-mapper escapes a literal dash by doubling it, so the VG/LV separator is the single
    dash. Splitting naively on "-" turns "data--vg-home" into VG "data" — a name that does not
    exist, and the restore would then create the wrong volume group.
    """
    marker = "\x00"
    protected = name.replace("--", marker)
    if "-" not in protected:
        return None
    vg, _, lv = protected.partition("-")
    return vg.replace(marker, "-"), lv.replace(marker, "-")


def plan_restore(layout: SourceLayout, target: Disk) -> RestorePlan:
    """Fit a captured layout onto `target`, giving the last volume whatever is left over.

    Rules, and each exists because of a way this goes wrong:

    * The target must hold the **used** data, not the source's disk size — that is the entire
      point of used-block imaging, and refusing on `disk_size` would reject a 500 GB source with
      8 GB of data going onto a 100 GB disk.
    * Fixed-size volumes stay fixed. Growing the ESP or /boot gains nothing and an ESP that is no
      longer the size the firmware recorded is a way to lose the boot path.
    * Only the **last** volume absorbs the remaining space, because it is the only one that can:
      everything after a grown volume would have to move.
    * A target smaller than the source still works as long as the data fits and only the last
      volume needs to shrink — but a shrink of a non-shrinkable filesystem (xfs) is refused
      rather than attempted.
    """
    if not layout.volumes:
        raise ImagingError("layout has no volumes to restore")
    if target.size < layout.used_total:
        raise ImagingError(
            f"target disk {target.name} is {target.size} bytes; the image needs at least "
            f"{layout.used_total} bytes of data"
        )

    fixed = layout.volumes[:-1]
    last = layout.volumes[-1]
    overhead = ALIGN + (GPT_TAIL_RESERVE if layout.label == "gpt" else 0)
    fixed_total = sum(v.size_bytes for v in fixed)
    remaining = target.size - overhead - fixed_total

    if remaining < last.used_bytes:
        raise ImagingError(
            f"target disk {target.name} leaves {remaining} bytes for {last.role!r}, which holds "
            f"{last.used_bytes} bytes of data"
        )

    last_size = _align_down(remaining)
    plan = RestorePlan(target_disk=target.name, target_size=target.size)
    for v in fixed:
        plan.volumes.append(PlannedVolume(volume=v, size_bytes=v.size_bytes, grow=False))

    if last_size > last.size_bytes:
        if last.fs_type not in GROWABLE:
            plan.notes.append(
                f"{last.role}: {last.fs_type} cannot be grown — restoring at its original size "
                f"and leaving {last_size - last.size_bytes} bytes unused"
            )
            last_size = last.size_bytes
            grow = False
        else:
            grow = True
    elif last_size < last.size_bytes:
        if last.fs_type == "xfs":
            # The one case that is genuinely impossible: xfs has no shrink, at all.
            raise ImagingError(
                f"{last.role} is xfs and would have to shrink from {last.size_bytes} to "
                f"{last_size} bytes; xfs cannot be shrunk"
            )
        plan.notes.append(f"{last.role}: restoring into a smaller container ({last_size} bytes)")
        grow = False
    else:
        grow = False

    plan.volumes.append(PlannedVolume(volume=last, size_bytes=last_size, grow=grow))
    if layout.lvm_on_raw_disk:
        plan.notes.append("source had LVM directly on the disk (no partition table) — reproduced as such")
    return plan


def _align_down(size: int) -> int:
    return (size // ALIGN) * ALIGN


# ---------------------------------------------------------------------------
# The commands. Built as data, executed by the caller.

# partclone ships one binary per filesystem (`partclone.ext4`, `partclone.xfs`, …). These are the
# ones we rely on; anything else falls back to `partclone.dd`, which still writes the partclone
# image format but copies every block instead of only the used ones — correct, just not thin.
#
# The list is deliberately short rather than exhaustive: the installed set varies by distribution
# and version, so `capture_pipeline`'s caller must check the binary exists (see
# `required_tools`) instead of trusting a table compiled from a package description.
_PARTCLONE = {
    "ext2": "partclone.ext2",
    "ext3": "partclone.ext3",
    "ext4": "partclone.ext4",
    "xfs": "partclone.xfs",
    "btrfs": "partclone.btrfs",
    "vfat": "partclone.vfat",
    "fat16": "partclone.fat16",
    "fat32": "partclone.fat32",
    "ntfs": "partclone.ntfs",
}

# Compression level for capture. 3 is zstd's default and the right trade here: the bottleneck is
# the disk and the network, not the CPU, and levels above ~6 cost far more time than they save
# bytes on filesystem images. `-T0` uses every core.
ZSTD_LEVEL = 3


def partclone_tool(fs_type: str) -> str:
    """The binary that images this filesystem, or `partclone.dd` when we have no better one.

    Falling back to `dd` mode rather than failing is the right call: a raw copy of an unexpected
    filesystem is still a correct backup, only a fat one. Refusing would block a whole host over
    one odd volume.
    """
    return _PARTCLONE.get((fs_type or "").lower(), "partclone.dd")


def required_tools(layout: SourceLayout) -> list[str]:
    """Every binary a capture of this layout needs, so the caller can verify before starting.

    Checking up front matters: a missing `partclone.xfs` discovered halfway through means a
    half-written image and a wasted transfer of everything before it.
    """
    tools = {"zstd"}
    for v in layout.volumes:
        tools.add(partclone_tool(v.fs_type))
    return sorted(tools)


def capture_pipeline(volume: Volume, *, device: str, sink: str, level: int = ZSTD_LEVEL) -> str:
    """`partclone.<fs> -c -s <device> | zstd | <sink>` — a shell pipeline, fully quoted.

    A pipeline needs a shell, so every interpolated value goes through `shlex.quote`. Device names
    come from `lsblk` and are tame, but `sink` is caller-supplied (a path or a URL), and an
    unquoted `;` there would run as a command with the privileges an imaging job necessarily has.

    `sink` is a parameter rather than a fixed destination because where the image lands is not
    decided yet — a local file that Bossman pulls, or a direct upload. Both are one string here.
    """
    tool = partclone_tool(volume.fs_type)
    return (
        f"{shlex.quote(tool)} -c -s {shlex.quote(device)} -o - "
        f"| zstd -T0 -{int(level)} "
        f"| {sink}"
    )


def restore_pipeline(*, source: str, device: str) -> str:
    """`<source> | zstd -dc | partclone.restore -o <device>`.

    `partclone.restore` rather than a per-filesystem binary: it reads the image's own header and
    picks the right handler, so the restore side needs no knowledge of what was captured. And it
    is emphatically not `dd` — the image holds only used blocks, so `dd` would write the metadata
    stream onto the disk as if it were data.
    """
    return f"{source} | zstd -dc | partclone.restore -s - -o {shlex.quote(device)}"


def fetch_command(url: str, *, retries: int = 5) -> str:
    """The reading half of a restore: `curl` with retries, failing loudly on a bad status.

    Not netcat. netcat has no length, no status and no resume, so a dropped connection yields a
    silently truncated stream — which, written to a disk, is an unbootable machine that looks like
    a successful restore. `-f` turns an HTML error page into a non-zero exit instead of writing it
    onto the filesystem.
    """
    return f"curl -fsSL --retry {int(retries)} --retry-all-errors {shlex.quote(url)}"


def sfdisk_script(layout: SourceLayout) -> str:
    """The partition table to write on the target, as an `sfdisk` script.

    Two things are delegated to sfdisk rather than computed here, both verified against the real
    tool (`sfdisk --json` on a file-backed table):

    * **Sizes carry a unit** (`size=512MiB`), so nothing here converts bytes to sectors. That
      matters more than it looks: a 4Kn target reports a 4096-byte sector, and sector counts
      computed against the source's 512 would be eight times wrong.
    * **The last partition gets an empty `size=`**, which claims the remainder *and leaves the
      GPT backup header its room* — measured: on a 2 GiB disk it took 510 MiB of the remaining
      511. `plan_restore`'s own tail arithmetic therefore exists to validate and to report, not
      to be written; letting both compute it would be two sources of truth that disagree the
      first time one is edited.

    `start=` is omitted throughout so sfdisk lays partitions out consecutively with its own
    alignment.
    """
    if not layout.partitions:
        raise ImagingError("layout has no partitions to write (LVM directly on the disk?)")
    lines = [f"label: {layout.label}", "unit: sectors", ""]
    last = layout.partitions[-1]
    for p in layout.partitions:
        size = "" if p is last else f"{p.size_bytes // (1024 * 1024)}MiB"
        lines.append(f"size={size}, type={p.kind}")
    return "\n".join(lines) + "\n"


def lvm_commands(layout: SourceLayout, *, pv_device: str) -> list[list[str]]:
    """Recreate the volume groups and logical volumes on the target.

    The last LV of each group is created with `-l 100%FREE` instead of an explicit size — the same
    reasoning as the partition table: LVM knows exactly how much room is left after its own
    metadata, and asking it beats computing it. That is also what makes the target's larger disk
    end up used rather than merely partitioned.

    Volumes are created in captured order, so "last" means the one that was last on the source —
    which is the one `plan_restore` marked as growable.
    """
    lvs = [v for v in layout.volumes if v.vg and v.lv]
    if not lvs:
        return []
    cmds: list[list[str]] = [["pvcreate", "-ff", "-y", pv_device]]
    by_vg: dict[str, list[Volume]] = {}
    for v in lvs:
        by_vg.setdefault(str(v.vg), []).append(v)
    for vg, members in by_vg.items():
        cmds.append(["vgcreate", vg, pv_device])
        for v in members[:-1]:
            cmds.append(["lvcreate", "-L", f"{v.size_bytes // (1024 * 1024)}m", "-n", str(v.lv), vg])
        cmds.append(["lvcreate", "-l", "100%FREE", "-n", str(members[-1].lv), vg])
    return cmds


def lv_device(volume: Volume) -> str:
    """The path a restored LV will have on the target.

    `/dev/<vg>/<lv>` rather than `/dev/mapper/<vg>-<lv>`: the mapper form needs the dash doubling
    that caused the parsing trouble in the first place, and the slash form has no escaping at all.
    """
    if volume.vg and volume.lv:
        return f"/dev/{volume.vg}/{volume.lv}"
    raise ImagingError(f"volume {volume.role!r} is not on LVM")


def layout_to_dict(layout: SourceLayout) -> dict[str, Any]:
    """The manifest as stored JSONB. Explicit rather than `asdict`, for two reasons.

    `asdict` would silently start persisting any field added later, so a rename would produce rows
    the reader cannot interpret — and this document has to be readable by a restore running months
    after the capture. Writing it out means a schema change is a visible edit here.

    `used_bytes` keeps `None` as null rather than collapsing to 0: the distinction is the whole
    reason it is nullable (see `Volume`), and JSON has a null, so there is no excuse to lose it.
    """
    return {
        "version": 1,
        "disk_size": layout.disk_size,
        "label": layout.label,
        "lvm_on_raw_disk": layout.lvm_on_raw_disk,
        "partitions": [
            {"number": p.number, "size_bytes": p.size_bytes, "kind": p.kind} for p in layout.partitions
        ],
        "volumes": [
            {
                "role": v.role,
                "fs_type": v.fs_type,
                "size_bytes": v.size_bytes,
                "used_bytes": v.used_bytes,
                "vg": v.vg,
                "lv": v.lv,
                "partition": v.partition,
                "mountpoint": v.mountpoint,
            }
            for v in layout.volumes
        ],
    }


def layout_from_dict(doc: dict[str, Any]) -> SourceLayout:
    """Read a stored manifest back, refusing a version this code does not understand.

    Refusing beats best-effort parsing here: a restore driven by a half-understood layout writes
    partitions to the wrong sizes, and the failure surfaces as a machine that will not boot rather
    than as an error anyone can act on.
    """
    version = int(doc.get("version") or 0)
    if version != 1:
        raise ImagingError(f"unsupported image manifest version {version!r} (this build reads 1)")
    return SourceLayout(
        disk_size=int(doc["disk_size"]),
        label=str(doc.get("label") or "gpt"),
        lvm_on_raw_disk=bool(doc.get("lvm_on_raw_disk")),
        partitions=tuple(
            Partition(number=int(p["number"]), size_bytes=int(p["size_bytes"]), kind=str(p["kind"]))
            for p in doc.get("partitions") or []
        ),
        volumes=tuple(
            Volume(
                role=str(v["role"]),
                fs_type=str(v["fs_type"]),
                size_bytes=int(v["size_bytes"]),
                used_bytes=None if v.get("used_bytes") is None else int(v["used_bytes"]),
                vg=v.get("vg"),
                lv=v.get("lv"),
                partition=None if v.get("partition") is None else int(v["partition"]),
                mountpoint=v.get("mountpoint"),
            )
            for v in doc.get("volumes") or []
        ),
    )


def with_measured_usage(layout: SourceLayout, used_by_role: dict[str, int]) -> SourceLayout:
    """Fill in the used sizes a capture measured, keyed by the image file's stem.

    This is the step that turns an unplannable manifest into a plannable one: partclone reports how
    many blocks it actually moved, which is the authoritative number and the only one available for
    a filesystem that was never mounted.
    """
    filled = tuple(
        v if v.used_bytes is not None else _with_used(v, used_by_role.get(image_stem(v)))
        for v in layout.volumes
    )
    return SourceLayout(
        disk_size=layout.disk_size,
        label=layout.label,
        partitions=layout.partitions,
        volumes=filled,
        lvm_on_raw_disk=layout.lvm_on_raw_disk,
    )


def _with_used(volume: Volume, used: int | None) -> Volume:
    if used is None:
        return volume
    return Volume(
        role=volume.role,
        fs_type=volume.fs_type,
        size_bytes=volume.size_bytes,
        used_bytes=int(used),
        vg=volume.vg,
        lv=volume.lv,
        partition=volume.partition,
        mountpoint=volume.mountpoint,
    )


@dataclass(frozen=True)
class Step:
    """One action in a restore run.

    `shell` marks a step that needs a shell because it is a pipeline; everything else is an argv
    list, which needs no quoting and cannot be misread. `chroot` marks a step that must run inside
    the restored system rather than in the helper — the distinction that makes the difference
    between installing GRUB into the target and installing it into the netboot initramfs.
    """

    name: str
    argv: tuple[str, ...] = ()
    shell: str = ""
    chroot: bool = False

    def __post_init__(self) -> None:
        if bool(self.argv) == bool(self.shell):
            raise ImagingError(f"step {self.name!r} must carry exactly one of argv or shell")


# Where the restored system is assembled in the helper.
TARGET_ROOT = "/mnt/target"

# The pseudo-filesystems a chroot needs before anything inside it works: package tools want
# /proc, device nodes come from /dev, and grub-install reads /sys to find the disk it is
# installing onto. Without them the chroot commands fail in ways that look like unrelated bugs.
#
# /dev/pts is deliberately absent: `--rbind /dev` carries its submounts along, so a separate entry
# is redundant — and not harmless, since it would fail on an image whose /dev/pts directory does
# not exist yet.
_BIND_MOUNTS = ("/dev", "/proc", "/sys", "/run")


def restore_steps(
    layout: SourceLayout,
    plan: RestorePlan,
    *,
    image_url: str,
    hostname: str,
    pv_partition: int | None = None,
) -> list[Step]:
    """The whole restore, as an ordered list the helper executes and reports on.

    Order is the substance here, and each rule below exists because getting it wrong produces a
    machine that does not boot rather than an error:

    1. Partition, then LVM, then restore — a filesystem cannot be written into a volume that does
       not exist yet.
    2. Grow immediately after the restore of that volume, while nothing else is mounted on top.
    3. Mount root FIRST, then /boot, then /boot/efi. Mounting a child before its parent hides the
       child; unmounting in the same order fails because the parent is busy — so teardown is
       strictly reversed.
    4. Bind-mount /dev, /proc, /sys before any chroot step, or `grub-install` cannot see the disk.
    5. Bootloader before identity reset, purely so a failure lands on the step that can still be
       diagnosed with a shell open.
    6. Identity reset LAST before unmount: machine-id, SSH host keys and hostname. Skipping it
       produces twins that fight over DHCP leases and present the same SSH fingerprint.
    """
    disk = f"/dev/{plan.target_disk}"
    steps: list[Step] = []

    # 1. Partition table (unless LVM sits on the raw disk), then the volume group.
    if layout.partitions:
        steps.append(Step(name="wipe partition table", argv=("wipefs", "-a", disk)))
        steps.append(Step(name="write partition table", shell=f"sfdisk {shlex.quote(disk)} < /tmp/target.sfdisk"))
        steps.append(Step(name="settle device nodes", argv=("udevadm", "settle")))
    pv = disk if layout.lvm_on_raw_disk else f"{disk}{_part_suffix(plan.target_disk, pv_partition or len(layout.partitions))}"
    for argv in lvm_commands(layout, pv_device=pv):
        steps.append(Step(name=f"lvm: {' '.join(argv[:2])}", argv=tuple(argv)))

    # 2. Restore each volume, growing the one that is meant to grow right after its own restore.
    for planned in plan.volumes:
        v = planned.volume
        device = lv_device(v) if v.vg else f"{disk}{_part_suffix(plan.target_disk, v.partition or 1)}"
        url = f"{image_url.rstrip('/')}/{_image_name(v)}"
        steps.append(
            Step(
                name=f"restore {v.role}",
                shell=restore_pipeline(source=fetch_command(url), device=device),
            )
        )
        for argv in grow_commands(planned, device=device, mountpoint=f"{TARGET_ROOT}-grow"):
            steps.append(Step(name=f"grow {v.role}: {argv[0]}", argv=tuple(argv)))

    # 3. Assemble the target tree, parents before children.
    for planned in _mount_order(plan):
        v = planned.volume
        device = lv_device(v) if v.vg else f"{disk}{_part_suffix(plan.target_disk, v.partition or 1)}"
        mp = TARGET_ROOT if v.mountpoint == "/" else f"{TARGET_ROOT}{v.mountpoint}"
        steps.append(Step(name=f"mkdir {mp}", argv=("mkdir", "-p", mp)))
        steps.append(Step(name=f"mount {v.role}", argv=("mount", device, mp)))

    # 4. The pseudo-filesystems a chroot needs.
    for src in _BIND_MOUNTS:
        steps.append(Step(name=f"bind {src}", argv=("mount", "--rbind", src, f"{TARGET_ROOT}{src}")))

    # 5. Bootloader.
    steps.append(Step(name="install bootloader", argv=("grub-install", disk), chroot=True))
    steps.append(Step(name="regenerate grub config", argv=("update-grub",), chroot=True))

    # 6. Identity: without this every clone is a twin.
    steps.extend(identity_steps(hostname))

    # Teardown, strictly reversed.
    for src in reversed(_BIND_MOUNTS):
        steps.append(Step(name=f"unbind {src}", argv=("umount", "-lR", f"{TARGET_ROOT}{src}")))
    for planned in reversed(_mount_order(plan)):
        v = planned.volume
        mp = TARGET_ROOT if v.mountpoint == "/" else f"{TARGET_ROOT}{v.mountpoint}"
        steps.append(Step(name=f"umount {v.role}", argv=("umount", mp)))
    return steps


def identity_steps(hostname: str) -> list[Step]:
    """Make the restored system a distinct machine rather than a copy of its source.

    Deliberately truncating `/etc/machine-id` rather than deleting it: systemd generates a new id
    at boot when the file exists and is EMPTY, while a missing file is a different (and on some
    images fatal) condition. `/var/lib/dbus/machine-id` follows it.

    SSH host keys are removed so the service regenerates them on first start. Leaving them means
    every machine from this image presents the same fingerprint — a warning your operators would
    learn to click through, which is worse than the inconvenience.
    """
    return [
        Step(name="reset machine-id", argv=("truncate", "-s", "0", f"{TARGET_ROOT}/etc/machine-id")),
        Step(name="reset dbus machine-id", shell=f"rm -f {shlex.quote(TARGET_ROOT)}/var/lib/dbus/machine-id"),
        Step(name="drop ssh host keys", shell=f"rm -f {shlex.quote(TARGET_ROOT)}/etc/ssh/ssh_host_*"),
        Step(
            name="set hostname",
            shell=f"printf '%s\\n' {shlex.quote(hostname)} > {shlex.quote(TARGET_ROOT)}/etc/hostname",
        ),
    ]


def _mount_order(plan: RestorePlan) -> list[PlannedVolume]:
    """Mountable volumes, parents before children.

    Sorting by path depth is what puts / before /boot before /boot/efi. Mounting a child first
    would hide it under the parent that lands on top of it.
    """
    mountable = [p for p in plan.volumes if p.volume.mountpoint]
    return sorted(mountable, key=lambda p: (str(p.volume.mountpoint).count("/"), str(p.volume.mountpoint)))


def _part_suffix(disk: str, number: int) -> str:
    """"3" for sda, "p3" for nvme0n1 — NVMe and mmc name partitions with a `p`.

    Getting this wrong yields `/dev/nvme0n13`, which does not exist, so the step fails loudly
    rather than writing somewhere wrong. Still worth being right about.
    """
    return f"p{number}" if disk and disk[-1].isdigit() else str(number)


def image_stem(volume: Volume) -> str:
    """The key a volume's image is stored and reported under — stable and collision-free.

    Keyed by role plus the LV name, because a layout can hold two volumes with the same role (two
    data LVs) and the role alone would make them overwrite each other in the store. Shared with
    `with_measured_usage`, so the capture's report and the restore's lookup cannot drift apart.
    """
    return f"{volume.role}-{volume.lv}" if volume.lv else volume.role


def _image_name(volume: Volume) -> str:
    return f"{image_stem(volume)}.pcl.zst"


def grow_commands(planned: PlannedVolume, *, device: str, mountpoint: str = "/mnt/target") -> list[list[str]]:
    """How to make the filesystem fill its new container — genuinely different per filesystem.

    ext* grows offline: `resize2fs <device>`, nothing mounted. xfs can ONLY be grown while
    mounted, and `xfs_growfs` takes the MOUNT POINT, not the device. Passing a device to
    xfs_growfs fails; passing a mountpoint to resize2fs fails. Getting this pair backwards is the
    classic way to end up with a restore that reports success and a filesystem that never uses the
    extra space.
    """
    if not planned.grow:
        return []
    fs = planned.volume.fs_type
    if fs == "xfs":
        return [
            ["mkdir", "-p", mountpoint],
            ["mount", device, mountpoint],
            ["xfs_growfs", mountpoint],
            ["umount", mountpoint],
        ]
    # e2fsck first: resize2fs refuses to touch a filesystem that has not been checked since its
    # last mount, and a freshly restored image always looks that way.
    return [
        ["e2fsck", "-fy", device],
        ["resize2fs", device],
    ]
