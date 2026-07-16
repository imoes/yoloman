"""The check library (Block G9): the flat on-disk store of monitoring
checks — Checkmk checks translated to read-only Starlark modules, plus
hand-authored "custom checks". Distinct from the Ansible module library
(services/module_library.py, per-collection under modules.d): a check is a
read-only Starlark module (writes:false) that gathers data on-host and
returns a verdict in `data` (state/metrics), and they all live FLAT in
checks_dir as <name>.{star,yaml} so "all checks, custom included, in one
place" (user decision).

Reuses module_library's Go validator (validate_star) — the same
starlark-check binary the agent runtime is built from, so a check that
validates here runs there. Only the on-disk layout (flat) and the metadata
(writes:false, kind:check) differ.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import nestedtext

from bossman.services.module_library import ModuleLibraryError, load_metadata, validate_star

_SNMP_CMD = re.compile(r'"(snmpwalk|snmpget|snmpbulkget|snmpbulkwalk|snmptable)"')
_SSH_CMD = re.compile(r'"(sshpass|scp)"|\[\s*"ssh"')


def check_datasource(star: str) -> str:
    """Which data source a check needs, read straight from its Starlark: SNMP
    checks ctx.run snmpwalk/snmpget; SSH checks sshpass/scp/ssh; else the local
    agent. Used to filter the catalog (SNMP devices offer only SNMP checks) and
    to keep discovery from running SNMP checks against a plain agent host."""
    if _SNMP_CMD.search(star):
        return "snmp"
    if _SSH_CMD.search(star):
        return "ssh"
    return "agent"


def check_paths(checks_dir: str | Path, name: str) -> tuple[Path, Path]:
    """The flat <checks_dir>/<name>.{nt,star} pair for one check. Metadata is
    NestedText (project convention — no YAML)."""
    base = Path(checks_dir)
    return base / f"{name}.nt", base / f"{name}.star"


def _parse_check_metadata(metadata_text: str, name: str) -> dict[str, Any]:
    try:
        meta = nestedtext.loads(metadata_text, top="dict")
    except nestedtext.NestedTextError as exc:
        raise ModuleLibraryError(f"check metadata is not valid NestedText: {exc}") from exc
    if not isinstance(meta, dict):
        raise ModuleLibraryError("check metadata must be a NestedText mapping")
    for key in ("name", "short_description", "options", "runtime"):
        if key not in meta:
            raise ModuleLibraryError(f"check metadata is missing required key: {key}")
    if meta["runtime"] != "starlark":
        raise ModuleLibraryError(f"runtime must be 'starlark', got {meta['runtime']!r}")
    if meta["name"] != name:
        raise ModuleLibraryError(f"metadata name {meta['name']!r} does not match check name {name!r}")
    if not isinstance(meta["options"], dict):
        raise ModuleLibraryError("options must be a mapping of option name -> spec")
    return meta


def submit_check(
    checks_dir: str | Path,
    starlark_check_path: str,
    name: str,
    metadata_text: str,
    star_code: str,
    params: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Validate (hard gate) then persist one check flat in checks_dir.
    `metadata_text` is NestedText. Returns {stored, paths, validation}."""
    _parse_check_metadata(metadata_text, name)
    result = validate_star(starlark_check_path, star_code, params)
    if not result.ok:
        return {"stored": False, "validation": result.to_dict()}
    nt_path, star_path = check_paths(checks_dir, name)
    nt_path.parent.mkdir(parents=True, exist_ok=True)
    nt_path.write_text(metadata_text, encoding="utf-8")
    star_path.write_text(star_code, encoding="utf-8")
    return {"stored": True, "paths": {"metadata": str(nt_path), "star": str(star_path)}, "validation": result.to_dict()}


def list_checks(checks_dir: str | Path) -> list[dict[str, Any]]:
    """Catalog listing: one entry per stored check (a <name>.star with a
    matching <name>.nt), enriched from the small NestedText metadata."""
    base = Path(checks_dir)
    out: list[dict[str, Any]] = []
    if not base.is_dir():
        return out
    for star in sorted(base.glob("*.star")):
        name = star.stem
        nt_path = base / f"{name}.nt"
        if not nt_path.exists():
            continue
        entry: dict[str, Any] = {"name": name, "kind": "check", "source": "translated"}
        try:
            meta = load_metadata(nt_path)
            entry["short_description"] = meta.get("short_description", "")
            entry["source"] = meta.get("source", "translated")
            entry["options"] = meta.get("options", {}) or {}
            entry["category"] = meta.get("category", "") or "Other"
        except (OSError, ModuleLibraryError):
            entry["options"] = {}
        try:
            entry["datasource"] = check_datasource(star.read_text(encoding="utf-8"))
        except OSError:
            entry["datasource"] = "agent"
        out.append(entry)
    return out


def load_check(checks_dir: str | Path, name: str) -> dict[str, Any]:
    """One stored check: parsed metadata + Starlark source."""
    nt_path, star_path = check_paths(checks_dir, name)
    if not nt_path.exists() or not star_path.exists():
        raise ModuleLibraryError(f"check {name!r} is not in the library")
    try:
        metadata = load_metadata(nt_path)
        star_code = star_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ModuleLibraryError(f"cannot read check {name!r}: {exc}") from exc
    return {"name": name, "metadata": metadata, "star_code": star_code}


def checks_status(checks_dir: str | Path, check_source_names: list[str]) -> dict[str, Any]:
    """Translation progress for the check batch: of the dumped source names
    (the universe), which are already stored. `check_source_names` are the
    flat check names (e.g. 'fileinfo', 'http')."""
    stored = {c["name"] for c in list_checks(checks_dir)}
    missing = sorted(n for n in check_source_names if n not in stored)
    return {"total": len(check_source_names), "translated": len(check_source_names) - len(missing), "missing": missing}
