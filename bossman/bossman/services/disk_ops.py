"""Disk operations — the gparted-style op queue + Apply (docs/disk-management.md,
Phase 2/3). A DiskPlan is an ORDERED list of typed operations; `compile` turns it
into concrete host commands, `preview` shows them + a safety verdict without
touching anything, and `apply` runs them over the agent `command` module.

SAFETY (first cut): apply refuses any operation whose target device is not a
loopback scratch device (/dev/loop*) unless `allow_nonloop=True` is passed
explicitly — so the destructive engine can be exercised for real against a
throwaway loop device without any chance of harming a system disk. A scratch loop
device is created/destroyed via `scratch_setup`/`scratch_teardown`. Before a
partition-table change the table is dumped (`sfdisk -d`) as a rollback point.
"""
from __future__ import annotations

import logging
import shlex
from typing import Any

logger = logging.getLogger(__name__)

# Filesystem → mkfs command + label tool (extend as more are validated).
_MKFS = {
    "ext2": ["mkfs.ext2", "-F"], "ext3": ["mkfs.ext3", "-F"], "ext4": ["mkfs.ext4", "-F"],
    "xfs": ["mkfs.xfs", "-f"], "btrfs": ["mkfs.btrfs", "-f"], "vfat": ["mkfs.vfat"],
    "fat32": ["mkfs.vfat", "-F", "32"], "exfat": ["mkfs.exfat"], "swap": ["mkswap"],
}


async def _run(client, argv: list[str]) -> tuple[int, str, str]:
    try:
        res = await client.call_tool("command", {"argv": argv})
    except Exception as exc:  # noqa: BLE001
        return 127, "", str(exc)[:300]
    data = (res or {}).get("data") if isinstance(res, dict) else {}
    if not isinstance(data, dict):
        return 1, "", "unexpected command result"
    return int(data.get("rc", 0) or 0), data.get("stdout", "") or "", data.get("stderr", "") or ""


def _part_path(dev: str, num) -> str:
    """device + partition number, with the 'p' separator for loop/nvme/mmc."""
    import re
    sep = "p" if re.search(r"(?:loop\d+|nvme\d+n\d+|mmcblk\d+)$", dev) else ""
    return f"{dev}{sep}{num}"


def _target_device(op: dict) -> str:
    """The block device an op acts on — its `device`, or the disk of its `target`."""
    dev = op.get("device") or ""
    if dev:
        return dev
    t = op.get("target") or ""
    # /dev/sda2 → /dev/sda ; /dev/loop0p1 → /dev/loop0 ; /dev/nvme0n1p2 → /dev/nvme0n1
    import re
    m = re.match(r"^(/dev/(?:loop\d+|nvme\d+n\d+|mmcblk\d+|[a-z]+))p?\d*$", t)
    return m.group(1) if m else t


def compile(plan: dict) -> list[dict]:
    """DiskPlan → ordered [{op, desc, argv, device, touches_table}]. Pure."""
    steps: list[dict] = []
    for op in plan.get("ops", []) or []:
        kind = op.get("op")
        dev = _target_device(op)
        if kind == "mklabel":
            table = op.get("table", "gpt")
            steps.append({"op": kind, "device": dev, "touches_table": True,
                          "desc": f"create {table} partition table on {dev}",
                          "argv": ["parted", "-s", dev, "mklabel", table]})
        elif kind == "mkpart":
            fstype = op.get("fstype", "ext4")
            start, end = op.get("start", "1MiB"), op.get("end", "100%")
            ptype = op.get("ptype", "primary")
            steps.append({"op": kind, "device": dev, "touches_table": True,
                          "desc": f"create {ptype} partition {start}→{end} on {dev}",
                          "argv": ["parted", "-s", "-a", "optimal", dev, "mkpart", ptype, fstype, start, end]})
        elif kind == "delete":
            num = str(op.get("num"))
            steps.append({"op": kind, "device": dev, "touches_table": True, "busy_target": _part_path(dev, num),
                          "desc": f"delete partition {num} on {dev}",
                          "argv": ["parted", "-s", dev, "rm", num]})
        elif kind == "mkfs":
            t = op.get("target")
            fstype = op.get("fstype", "ext4")
            base = _MKFS.get(fstype)
            if not base:
                steps.append({"op": kind, "device": dev, "error": f"unsupported fstype {fstype!r}",
                              "desc": f"format {t} as {fstype} (UNSUPPORTED)", "argv": []})
            else:
                steps.append({"op": kind, "device": dev, "touches_table": False, "busy_target": t,
                              "desc": f"format {t} as {fstype}", "argv": base + [t]})
        elif kind == "label":
            t, label, fstype = op.get("target"), op.get("label", ""), op.get("fstype", "ext4")
            argv = (["e2label", t, label] if fstype.startswith("ext")
                    else ["xfs_admin", "-L", label, t] if fstype == "xfs"
                    else ["fatlabel", t, label] if fstype in ("vfat", "fat32") else [])
            steps.append({"op": kind, "device": dev, "touches_table": False, "busy_target": t,
                          "desc": f"label {t} = {label!r}", "argv": argv})
        elif kind == "resize":
            # Resize a raw partition's filesystem + the partition itself, in the
            # ORDER that keeps data safe (gparted's rule): shrink FS then partition;
            # grow partition then FS. ext* only (xfs can't shrink); shrink needs the
            # FS unmounted — enforced in safety_check via busy_target.
            t, num, fstype = op.get("target"), str(op.get("num")), op.get("fstype", "ext4")
            start_mib, size_mib = int(op.get("start_mib") or 1), int(op.get("size_mib") or 0)
            grow = bool(op.get("grow"))
            if not fstype.startswith("ext") or size_mib <= 0:
                steps.append({"op": kind, "device": dev, "error": f"resize supported for ext* with a size (got {fstype})",
                              "desc": f"resize {t} (UNSUPPORTED)", "argv": []})
            elif grow:
                end = f"{start_mib + size_mib}MiB"
                steps.append({"op": kind, "device": dev, "touches_table": True, "busy_target": t,
                              "desc": f"grow partition {num} to {end}",
                              "argv": ["parted", "-s", dev, "unit", "MiB", "resizepart", num, end]})
                steps.append({"op": kind, "device": dev, "touches_table": False, "busy_target": t,
                              "desc": f"grow filesystem {t} to fill", "argv": ["resize2fs", t]})
            else:  # shrink: fsck → shrink fs → shrink partition (with a small margin)
                end = f"{start_mib + size_mib + 2}MiB"
                steps.append({"op": kind, "device": dev, "touches_table": False, "busy_target": t,
                              "desc": f"check filesystem {t}", "argv": ["e2fsck", "-f", "-y", t]})
                steps.append({"op": kind, "device": dev, "touches_table": False, "busy_target": t,
                              "desc": f"shrink filesystem {t} to {size_mib}MiB", "argv": ["resize2fs", t, f"{size_mib}M"]})
                # parted resizepart prompts "are you sure?" on a SHRINK even with -s, and
                # then hangs; feed it a tty (---pretend-input-tty) and answer Yes.
                shrink_cmd = f"printf 'Yes\\n' | parted ---pretend-input-tty {shlex.quote(dev)} unit MiB resizepart {shlex.quote(num)} {shlex.quote(end)}"
                steps.append({"op": kind, "device": dev, "touches_table": True, "busy_target": t,
                              "desc": f"shrink partition {num} to {end}",
                              "argv": ["sh", "-c", shrink_cmd]})
        elif kind == "mount":
            t, mp = op.get("target"), op.get("mountpoint")
            steps.append({"op": kind, "device": dev, "touches_table": False,
                          "desc": f"mount {t} at {mp}",
                          "argv": ["sh", "-c", f"mkdir -p {shlex.quote(mp)} && mount {shlex.quote(t)} {shlex.quote(mp)}"]})
        elif kind == "umount":
            t = op.get("target")
            steps.append({"op": kind, "device": dev, "touches_table": False,
                          "desc": f"unmount {t}", "argv": ["umount", t]})
        elif kind == "lvextend":
            t = op.get("target")
            size = str(op.get("size", ""))
            flag = "-l" if "%" in size else "-L"   # -l for extents (100%FREE), -L for a byte size
            steps.append({"op": kind, "device": dev, "touches_table": False,
                          "desc": f"grow LV {t} by {size} (online, --resizefs)",
                          "argv": ["lvextend", "--resizefs", flag, size, t]})
        else:
            steps.append({"op": kind, "device": dev, "error": f"unknown op {kind!r}",
                          "desc": f"unknown op {kind!r}", "argv": []})
    return steps


def _busy_index(layout: dict) -> tuple[set[str], set[str]]:
    """Returns (busy_paths, protected_devices): individual mounted paths, and the
    top-level disks that carry ANY mounted filesystem (down through LVM/LUKS
    children) — those disks must never be repartitioned, even with allow_nonloop."""
    busy: set[str] = set()
    protected: set[str] = set()

    def walk(node: dict) -> bool:
        has_busy = bool(node.get("busy"))
        for c in node.get("children", []) or []:
            has_busy = walk(c) or has_busy
        if node.get("busy"):
            busy.add(node.get("path"))
        return has_busy

    for d in layout.get("devices", []) or []:
        dev_busy = False
        for p in d.get("partitions", []) or []:
            dev_busy = walk(p) or dev_busy
        if dev_busy:
            protected.add(d.get("path"))
    return busy, protected


# Mounts we must never let an unmount workflow tear down (would break the host).
_CRITICAL_MOUNTS = {"/", "/boot", "/boot/efi", "/usr", "/var", "/etc", "/bin", "/sbin",
                    "/lib", "/lib64", "[SWAP]"}


def _mount_by_path(layout: dict) -> dict[str, str | None]:
    out: dict[str, str | None] = {}

    def walk(node: dict) -> None:
        out[node.get("path")] = node.get("mountpoint")
        for c in node.get("children", []) or []:
            walk(c)
    for d in layout.get("devices", []) or []:
        for p in d.get("partitions", []) or []:
            walk(p)
    return out


def safety_check(steps: list[dict], layout: dict, *, allow_nonloop: bool) -> list[dict]:
    """Design-time guardrails. Returns problems [{severity, message}]. errors block
    apply; warnings don't."""
    problems: list[dict] = []
    busy, protected = _busy_index(layout)
    mp_by_path = _mount_by_path(layout)
    for s in steps:
        if s.get("error"):
            problems.append({"severity": "error", "message": s["desc"]})
        dev = s.get("device") or ""
        is_loop = dev.startswith("/dev/loop")
        if not is_loop and not allow_nonloop:
            problems.append({"severity": "error",
                             "message": f"{s['desc']}: refused — {dev} is not a loopback scratch device "
                                        "(pass allow_nonloop to operate on a real disk)"})
        # umount is the workflow that FREES a busy filesystem for editing, so it is
        # exempt from the busy/protected guards — but must never tear down a
        # critical system mount.
        if s["op"] == "umount":
            tgt = (s.get("argv") or [None])[-1]
            mp = mp_by_path.get(tgt)
            if mp in _CRITICAL_MOUNTS:
                problems.append({"severity": "error",
                                 "message": f"{s['desc']}: refused — {tgt} is a critical system mount ({mp})"})
            continue
        # lvextend GROW is an online operation (LVM + ext4/xfs grow while mounted),
        # so it is exempt from the busy/protected guards — but only a grow (+…).
        if s["op"] == "lvextend":
            size = (s.get("argv") or ["", "", "", ""])[3]
            if not str(size).startswith("+"):
                problems.append({"severity": "error",
                                 "message": f"{s['desc']}: refused — only online GROW (size starting with '+') is allowed"})
            continue
        # HARD guard: never touch a disk that has mounted filesystems, even with
        # allow_nonloop — this is what protects the system/root disk.
        if dev in protected:
            problems.append({"severity": "error",
                             "message": f"{s['desc']}: refused — {dev} has mounted filesystem(s); unmount them first"})
        tgt = s.get("busy_target")
        if s["op"] in ("mkfs", "label", "delete", "resize") and tgt and tgt in busy:
            problems.append({"severity": "error",
                             "message": f"{s['desc']}: refused — {tgt} is mounted; unmount it first"})
    return problems


_PKG_FOR_BIN = {
    "parted": "parted", "mkfs.ext2": "e2fsprogs", "mkfs.ext3": "e2fsprogs", "mkfs.ext4": "e2fsprogs",
    "e2label": "e2fsprogs", "mkfs.xfs": "xfsprogs", "xfs_admin": "xfsprogs", "mkfs.btrfs": "btrfs-progs",
    "mkfs.vfat": "dosfstools", "fatlabel": "dosfstools", "mkfs.exfat": "exfatprogs", "sfdisk": "util-linux",
    "resize2fs": "e2fsprogs", "e2fsck": "e2fsprogs", "lvextend": "lvm2",
}


async def _ensure_tools(client, steps: list[dict]) -> tuple[list[str], list[str]]:
    """Preflight: make sure the binaries the plan needs exist; best-effort install
    the owning package via the host's package manager. Returns (installed, missing)."""
    needed: set[str] = set()
    for s in steps:
        argv = s.get("argv") or []
        if s.get("touches_table"):
            needed.add("parted")
            needed.add("sfdisk")  # table backup
        if s["op"] in ("mkfs", "label", "resize", "lvextend") and argv:
            needed.add(argv[0])
    installed: list[str] = []
    missing: list[str] = []
    for binname in sorted(needed):
        rc, _, _ = await _run(client, ["sh", "-c", f"command -v {shlex.quote(binname)}"])
        if rc == 0:
            continue
        pkg = _PKG_FOR_BIN.get(binname)
        if pkg:
            install = (
                f"if command -v apt-get >/dev/null; then export DEBIAN_FRONTEND=noninteractive; "
                f"apt-get update -qq && apt-get install -y -qq {pkg}; "
                f"elif command -v dnf >/dev/null; then dnf install -y {pkg}; "
                f"elif command -v yum >/dev/null; then yum install -y {pkg}; "
                f"elif command -v zypper >/dev/null; then zypper --non-interactive install {pkg}; fi"
            )
            await _run(client, ["sh", "-c", install])
            rc2, _, _ = await _run(client, ["sh", "-c", f"command -v {shlex.quote(binname)}"])
            if rc2 == 0:
                installed.append(pkg)
                continue
        missing.append(binname)
    return installed, missing


async def apply(agent, client_factory, settings, plan: dict, layout: dict, *, allow_nonloop: bool = False) -> dict:
    """Run the plan on the host. Refuses on any safety error. Dumps the partition
    table (sfdisk -d) of each touched device first as a rollback point. Stops at
    the first failed step. Returns {ok, steps:[…], table_backup:{dev:dump}}."""
    steps = compile(plan)
    problems = safety_check(steps, layout, allow_nonloop=allow_nonloop)
    if any(p["severity"] == "error" for p in problems):
        return {"ok": False, "refused": True, "problems": problems, "steps": []}

    client = client_factory(agent, settings)
    # preflight: ensure the tools the plan needs exist (best-effort install)
    installed, missing = await _ensure_tools(client, steps)
    if missing:
        return {"ok": False, "refused": True, "tools_installed": installed,
                "problems": [{"severity": "error", "message": f"missing tools (install failed): {', '.join(missing)}"}],
                "steps": []}
    # rollback point: dump the table of every device whose table we touch
    table_backup: dict[str, str] = {}
    for dev in {s["device"] for s in steps if s.get("touches_table")}:
        rc, out, _ = await _run(client, ["sfdisk", "-d", dev])
        if rc == 0:
            table_backup[dev] = out

    results: list[dict] = []
    ok = True
    for s in steps:
        if not s.get("argv"):
            results.append({"desc": s["desc"], "ok": False, "error": s.get("error", "no command")})
            ok = False
            break
        rc, out, err = await _run(client, s["argv"])
        step_ok = rc == 0
        results.append({"desc": s["desc"], "argv": s["argv"], "rc": rc,
                        "ok": step_ok, "output": (out + err).strip()[:500]})
        if not step_ok:
            ok = False
            break
    return {"ok": ok, "problems": problems, "steps": results, "table_backup": table_backup,
            "tools_installed": installed}


async def scratch_setup(agent, client_factory, settings, *, size_mb: int = 256) -> dict:
    """Create a throwaway loopback disk (a sparse file + losetup) so disk ops can
    be tested for real without a spare disk. Returns {ok, device, backing_file}."""
    client = client_factory(agent, settings)
    size_mb = max(16, min(size_mb, 4096))
    script = (
        f"f=$(mktemp /var/tmp/bm-scratch.XXXXXX.img) && truncate -s {size_mb}M \"$f\" "
        f"&& dev=$(losetup --find --show \"$f\") && echo \"$dev|$f\""
    )
    rc, out, err = await _run(client, ["sh", "-c", script])
    if rc != 0 or "|" not in out:
        return {"ok": False, "error": (err or out or "losetup failed")[:300]}
    dev, backing = out.strip().split("|", 1)
    return {"ok": True, "device": dev, "backing_file": backing}


async def scratch_teardown(agent, client_factory, settings, *, device: str, backing_file: str) -> dict:
    """Detach + delete a scratch loopback disk created by scratch_setup."""
    if not device.startswith("/dev/loop"):
        return {"ok": False, "error": "refused — not a loop device"}
    client = client_factory(agent, settings)
    bf = shlex.quote(backing_file) if backing_file else ""
    script = f"umount {shlex.quote(device)}* 2>/dev/null; losetup -d {shlex.quote(device)}; " + (f"rm -f {bf}" if bf else "true")
    rc, out, err = await _run(client, ["sh", "-c", script])
    return {"ok": rc == 0, "output": (out + err).strip()[:300]}
