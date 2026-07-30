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
class SourceLayout:
    """The captured shape of a source disk — the manifest that travels with the image."""

    disk_size: int
    label: str = "gpt"  # gpt | dos
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
    # LVM directly on the disk: the disk itself is the PV, so there is no partition table to
    # recreate. A real layout — this host's sdb is exactly that.
    lvm_on_raw = str(lsblk_disk.get("fstype") or "").lower() == "lvm2_member"

    def visit(node: dict[str, Any], partition: int | None, vg_lv: tuple[str, str] | None) -> None:
        fs = str(node.get("fstype") or "").lower()
        name = str(node.get("name") or "")
        kind = str(node.get("type") or "")

        if kind == "part":
            partition = _partition_number(name)
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
    return SourceLayout(
        disk_size=disk_size,
        label=label,
        volumes=tuple(volumes),
        lvm_on_raw_disk=lvm_on_raw,
    )


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
