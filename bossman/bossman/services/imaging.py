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
    """

    role: str  # "esp" | "boot" | "root" | "data" | ...
    fs_type: str
    size_bytes: int
    used_bytes: int
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
    def used_total(self) -> int:
        return sum(v.used_bytes for v in self.volumes)


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
