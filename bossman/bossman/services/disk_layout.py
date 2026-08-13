"""Read a host's disk + partition layout for the gparted-style Disks view.

Runs `lsblk` (partitions, fs, mount, used/avail) and `parted … print free`
(partition-table type + FREE segments in sectors) on the host via the agent's
generic `command` module, and merges them into one structured layout. Read-only —
this is the SCAN half (docs/disk-management.md, Phase 1). parted is best-effort:
if it's missing/denied, the lsblk view still returns (without free-space gaps).
"""
from __future__ import annotations

import json
import logging
from typing import Any

logger = logging.getLogger(__name__)

# Pseudo/virtual block devices with no partition-editing value (mirror the
# inventory collector's skip list).
_SKIP_PREFIXES = ("loop", "ram", "zram", "fd", "sr")


async def _run(client, argv: list[str]) -> tuple[int, str, str]:
    try:
        res = await client.call_tool("command", {"argv": argv})
    except Exception as exc:  # noqa: BLE001
        return 127, "", str(exc)[:300]
    data = (res or {}).get("data") if isinstance(res, dict) else {}
    if not isinstance(data, dict):
        return 1, "", "unexpected command result"
    return int(data.get("rc", 0) or 0), data.get("stdout", "") or "", data.get("stderr", "") or ""


def _mountpoint(node: dict) -> str | None:
    mp = node.get("mountpoint")
    if mp:
        return mp
    mps = node.get("mountpoints")  # newer lsblk: array (may hold [null])
    if isinstance(mps, list):
        for m in mps:
            if m:
                return m
    return None


def _int(v: Any) -> int | None:
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _partition_from_lsblk(node: dict) -> dict:
    size = _int(node.get("size"))
    avail = _int(node.get("fsavail"))
    used = _int(node.get("fsused"))
    mp = _mountpoint(node)
    return {
        "name": node.get("name"), "path": node.get("path") or f"/dev/{node.get('name')}",
        "kind": node.get("type"),  # part | lvm | crypt | …
        "size_bytes": size, "fstype": node.get("fstype"), "label": node.get("label"),
        "uuid": node.get("uuid"), "mountpoint": mp, "used_bytes": used, "avail_bytes": avail,
        "flags": [f for f in (node.get("partflags") or "").split(",") if f],
        "busy": bool(mp),
        "children": [_partition_from_lsblk(c) for c in (node.get("children") or [])],
    }


def _parse_parted(stdout: str) -> tuple[str | None, list[dict], int | None]:
    """Machine-readable `parted -m … unit s print free` → (table_type, segments,
    sector_size). Segments are partitions AND free gaps, in sectors."""
    table: str | None = None
    sector: int | None = None
    segments: list[dict] = []
    for raw in stdout.splitlines():
        line = raw.strip().rstrip(";")
        if not line or line == "BYT":
            continue
        f = line.split(":")
        if f[0].startswith("/dev/"):
            # device line: path:size:transport:logical:physical:table:model:
            if len(f) >= 6:
                table = f[5] or None
                sector = _int(f[3])
            continue
        # partition/free line: num:start:end:size:fstype:name:flags
        def sect(x: str) -> int | None:
            return _int(x[:-1] if x.endswith("s") else x)
        seg = {
            "num": _int(f[0]) if len(f) > 0 else None,
            "start_s": sect(f[1]) if len(f) > 1 else None,
            "end_s": sect(f[2]) if len(f) > 2 else None,
            "size_s": sect(f[3]) if len(f) > 3 else None,
            "fstype": f[4] if len(f) > 4 else "",
        }
        seg["free"] = (len(f) > 4 and f[4] == "free") or (len(f) > 5 and f[5] == "free")
        segments.append(seg)
    return table, segments, sector


async def read_disk_layout(agent, client_factory, settings) -> dict:
    """Scan one host's disks. Returns {devices:[…], errors:[…]}. Never raises."""
    if not agent.address:
        return {"devices": [], "errors": ["host has no reachable address"]}
    client = client_factory(agent, settings)
    errors: list[str] = []

    rc, out, err = await _run(client, ["lsblk", "-b", "-J", "-O"])
    if rc != 0 or not out.strip():
        return {"devices": [], "errors": [f"lsblk failed (rc={rc}): {err[:200]}"]}
    try:
        tree = json.loads(out)
    except ValueError as exc:
        return {"devices": [], "errors": [f"lsblk JSON parse failed: {exc}"]}

    devices: list[dict] = []
    for node in tree.get("blockdevices", []) or []:
        name = node.get("name") or ""
        if node.get("type") != "disk" or any(name.startswith(p) for p in _SKIP_PREFIXES):
            continue
        path = node.get("path") or f"/dev/{name}"
        dev = {
            "name": name, "path": path, "size_bytes": _int(node.get("size")),
            "model": (node.get("model") or "").strip(), "rotational": node.get("rota") in (True, "1", 1),
            "transport": node.get("tran"), "table": None, "sector_size": None,
            "partitions": [_partition_from_lsblk(c) for c in (node.get("children") or [])],
            "free": [],
        }
        # best-effort parted overlay: table type + FREE segments in sectors
        prc, pout, perr = await _run(client, ["parted", "-m", "-s", path, "unit", "s", "print", "free"])
        if prc == 0 and pout.strip():
            table, segs, sector = _parse_parted(pout)
            dev["table"] = table
            dev["sector_size"] = sector
            dev["free"] = [
                {"start_s": s["start_s"], "end_s": s["end_s"],
                 "size_bytes": (s["size_s"] * sector) if (s.get("size_s") and sector) else None}
                for s in segs if s.get("free") and (s.get("size_s") or 0) > 1
            ]
            # graft start/end sectors onto matching partitions (by num)
            by_num = {s["num"]: s for s in segs if not s["free"] and s.get("num") is not None}
            for i, p in enumerate(dev["partitions"], start=1):
                s = by_num.get(i)
                if s:
                    p["start_s"], p["end_s"] = s.get("start_s"), s.get("end_s")
        elif prc != 0:
            errors.append(f"parted on {path}: rc={prc} {perr[:120]}")
        devices.append(dev)

    vgs = await _read_lvm(client, errors)
    zfs = await _read_zfs(client)
    return {"devices": devices, "vgs": vgs, "zfs": zfs, "errors": errors}


async def _read_zfs(client) -> dict:
    """ZFS pools + datasets (used/avail/quota/mountpoint), so the Disks view can
    show and manage ZFS alongside partitions/LVM. Best-effort: a host without ZFS
    (no zpool/zfs binary, or module not loaded) returns {available: False} — never
    an error, mirroring the storage-overview endpoint's degradation."""
    prc, pout, _ = await _run(client, [
        "zpool", "list", "-Hp", "-o", "name,size,alloc,free,health,frag,cap"])
    if prc != 0:
        return {"available": False}
    pools: list[dict] = []
    for line in pout.splitlines():
        c = line.split("\t")
        if len(c) >= 5:
            pools.append({"name": c[0], "size_bytes": _int(c[1]), "alloc_bytes": _int(c[2]),
                          "free_bytes": _int(c[3]), "health": c[4],
                          "frag": c[5] if len(c) > 5 else None, "cap": c[6] if len(c) > 6 else None})
    # datasets: filesystems + volumes + snapshots, with the size-shaping properties
    drc, dout, _ = await _run(client, [
        "zfs", "list", "-Hp", "-t", "all", "-o",
        "name,type,used,avail,refer,quota,refquota,reservation,refreservation,mountpoint"])
    datasets: list[dict] = []
    if drc == 0:
        def _prop(x: str):  # zfs prints '-' or '0' for "none"
            return None if x in ("-", "none") else _int(x)
        for line in dout.splitlines():
            c = line.split("\t")
            if len(c) < 10:
                continue
            datasets.append({
                "name": c[0], "type": c[1], "used_bytes": _int(c[2]), "avail_bytes": _int(c[3]),
                "refer_bytes": _int(c[4]), "quota_bytes": _prop(c[5]), "refquota_bytes": _prop(c[6]),
                "reservation_bytes": _prop(c[7]), "refreservation_bytes": _prop(c[8]),
                "mountpoint": None if c[9] in ("-", "none") else c[9],
            })
    return {"available": True, "pools": pools, "datasets": datasets}


async def _read_lvm(client, errors: list[str]) -> list[dict]:
    """LVM volume groups + logical volumes (name, size, FREE extents) — so the
    view shows LVM and an LV can be created in a VG's free space. Best-effort:
    hosts without LVM simply return []."""
    vgrc, vgout, _ = await _run(client, [
        "vgs", "--reportformat", "json", "--units", "b", "--nosuffix",
        "-o", "vg_name,vg_size,vg_free"])
    if vgrc != 0 or not vgout.strip():
        return []  # no LVM (or lvm2 not installed) — not an error worth surfacing
    try:
        vg_report = json.loads(vgout)
        vg_rows = vg_report["report"][0]["vg"]
    except (ValueError, KeyError, IndexError):
        return []
    lvrc, lvout, _ = await _run(client, [
        "lvs", "--reportformat", "json", "--units", "b", "--nosuffix",
        "-o", "lv_name,vg_name,lv_size,lv_path"])
    lv_by_vg: dict[str, list[dict]] = {}
    try:
        for lv in json.loads(lvout)["report"][0]["lv"]:
            lv_by_vg.setdefault(lv["vg_name"], []).append({
                "name": lv["lv_name"], "path": lv.get("lv_path"), "size_bytes": _int(lv.get("lv_size"))})
    except (ValueError, KeyError, IndexError):
        pass
    vgs = []
    for vg in vg_rows:
        vgs.append({
            "name": vg["vg_name"], "size_bytes": _int(vg.get("vg_size")),
            "free_bytes": _int(vg.get("vg_free")), "lvs": lv_by_vg.get(vg["vg_name"], [])})
    return vgs
