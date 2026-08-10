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

import yaml

from bossman.services.module_library import ModuleLibraryError, load_metadata, validate_star

_SNMP_CMD = re.compile(r'"(snmpwalk|snmpget|snmpbulkget|snmpbulkwalk|snmptable)"')
_SSH_CMD = re.compile(r'"(sshpass|scp)"|\[\s*"ssh"')

# A check is "unrunnable" here when its ONLY way to get data is a Checkmk
# internal path or a Checkmk/cmk CLI invocation — i.e. the LLM translated the
# plugin by wrapping Checkmk's own agent/SNMP collection instead of reading the
# system directly, so it can never produce real data on our agent. Kept in sync
# with the discovery pre-filter (bossman.api.checks imports check_runnable).
_UNRUNNABLE_MARKERS = (
    "/var/lib/check_mk", "/var/lib/checkmk", "check_mk_agent", "checkmk_agent",
    "/opt/checkmk", "/omd/", "agent_output", "agent-output", "agent_raw",
    '"cmk"', "'cmk'", '"checkmk"', "'checkmk'", "cmk -d", "cmk -j",
    "--print-agent-table", "print-agent-table",
)


def check_runnable(star: str) -> bool:
    """False if the check can only get data from a Checkmk-internal source /
    the cmk CLI (or fabricated `echo '<<<section>>>'` output) — such checks are
    mistranslations that never work on our agent, so the catalog + discovery
    exclude them."""
    if any(m in star for m in _UNRUNNABLE_MARKERS):
        return False
    if '"echo"' in star and "<<<" in star:
        return False
    return True


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
    """The flat <checks_dir>/<name>.{yaml,star} pair for one check.

    Metadata is YAML. It used to be NestedText; the `.nt` path is still accepted when only that exists, so a
    tree that has not been converted yet keeps loading (see scripts/convert_sidecars_to_yaml.py). WRITES go
    to `.yaml` — the first element is what callers create."""
    base = Path(checks_dir)
    yml = base / f"{name}.yaml"
    nt = base / f"{name}.nt"
    return (nt if not yml.exists() and nt.exists() else yml), base / f"{name}.star"


def _parse_check_metadata(metadata_text: str, name: str) -> dict[str, Any]:
    try:
        meta = yaml.safe_load(metadata_text)
    except yaml.YAMLError as exc:
        raise ModuleLibraryError(f"check metadata is not valid YAML: {exc}") from exc
    if not isinstance(meta, dict):
        raise ModuleLibraryError("check metadata must be a YAML mapping")
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
    `metadata_text` is YAML. Returns {stored, paths, validation}."""
    _parse_check_metadata(metadata_text, name)
    result = validate_star(starlark_check_path, star_code, params)
    if not result.ok:
        return {"stored": False, "validation": result.to_dict()}
    meta_path, star_path = check_paths(checks_dir, name)
    meta_path.parent.mkdir(parents=True, exist_ok=True)
    meta_path.write_text(metadata_text, encoding="utf-8")
    star_path.write_text(star_code, encoding="utf-8")
    return {"stored": True, "paths": {"metadata": str(meta_path), "star": str(star_path)},
            "validation": result.to_dict()}


# Older translations baked a boilerplate lead sentence into the description
# ("Checkmk check 'x' (service: …), translated to a read-only on-host Starlark
# check module."). The dump generator no longer emits it, but ~450 catalog
# entries still carry it. Strip it at serve time so no consumer (UI, chat, MCP,
# docs summary) ever shows the internal "Checkmk … translated to Starlark"
# wording; a real, retranslated description (which never matches) passes through
# untouched. This does NOT hide the marker from retranslate_checks.py, which
# selects on prompt_version / empty-options / unrunnable — not on this text.
_CHECK_BOILERPLATE = re.compile(
    r"(?:checkmk|monitoring)\s+check\s+'[^']*'"          # Checkmk/Monitoring check 'name'
    r"(?:\s*\(service:[^)]*\))?"                          # optional (service: …)
    r"\s*[,—-]?\s*"
    r"(?:translated\s+to\s+a\s+)?read-only\s+on-host\s+starlark\s+check(?:\s+module)?\.?",
    re.IGNORECASE,
)


def _humanized_label(short: str) -> str:
    """A plain label from the service-name template ("Interface %s" → "Interface")."""
    label = re.sub(r"%s", "", short or "")
    label = re.sub(r"\s+", " ", label).strip(" -:—").strip()
    return label


def clean_check_description(description: str, short: str = "") -> str:
    """Drop the translator boilerplate from a check description for display.

    A description with real prose (no boilerplate) is returned verbatim. One that
    is only boilerplate is replaced by a clean sentence built from the short
    description, so the reader gets "Monitors Interface on this host." instead of
    "Checkmk check 'lnx_if' … translated to a read-only on-host Starlark …"."""
    if not description:
        label = _humanized_label(short)
        return f"Monitors {label} on this host." if label else ""
    if not _CHECK_BOILERPLATE.search(description):
        return description
    stripped = _CHECK_BOILERPLATE.sub("", description).strip(" ,.—-\n\t").strip()
    if stripped:
        return stripped
    label = _humanized_label(short)
    return f"Monitors {label} on this host." if label else "On-host monitoring check."


def _summary(description: str, limit: int = 240) -> str:
    """First prose sentence(s) of a markdown check description — skip headings,
    blockquote/`>` markers and blank lines; stop at the next heading. Used as the
    catalog/device-picker explanation."""
    if not description:
        return ""
    lines = []
    for raw in description.splitlines():
        s = raw.strip().lstrip(">").strip()
        if not s:
            if lines:
                break
            continue
        if s.startswith("#"):
            if lines:
                break
            continue  # skip the "## Overview" heading, keep reading
        lines.append(s)
        if sum(len(x) for x in lines) >= limit:
            break
    text = " ".join(lines).strip()
    return (text[:limit] + "…") if len(text) > limit else text


def list_checks(checks_dir: str | Path) -> list[dict[str, Any]]:
    """Catalog listing: one entry per stored check (a <name>.star with a
    matching <name>.nt), enriched from the small NestedText metadata."""
    base = Path(checks_dir)
    out: list[dict[str, Any]] = []
    if not base.is_dir():
        return out
    for star in sorted(base.glob("*.star")):
        name = star.stem
        # Prefer the YAML sidecar; fall back to a not-yet-converted `.nt`.
        meta_path = base / f"{name}.yaml"
        if not meta_path.exists():
            meta_path = base / f"{name}.nt"
        if not meta_path.exists():
            continue
        entry: dict[str, Any] = {"name": name, "kind": "check", "source": "translated"}
        try:
            meta = load_metadata(meta_path)
            entry["short_description"] = meta.get("short_description", "")
            entry["source"] = meta.get("source", "translated")
            entry["options"] = meta.get("options", {}) or {}
            entry["category"] = meta.get("category", "") or "Other"
            # A one-paragraph plain-text summary so a picker (the SNMP/SSH device
            # editor, the check catalog) can EXPLAIN what a script does without a
            # second round-trip to GET /checks/{name}. Derived from the markdown
            # description's Overview: the first real prose line, headers/blockquote
            # markers stripped.
            entry["summary"] = _summary(
                clean_check_description(meta.get("description", ""), entry["short_description"]))
        except (OSError, ModuleLibraryError):
            entry["options"] = {}
        try:
            src = star.read_text(encoding="utf-8")
            entry["datasource"] = check_datasource(src)
            entry["runnable"] = check_runnable(src)
        except OSError:
            entry["datasource"] = "agent"
            entry["runnable"] = True
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
    # Serve a display-clean description (drops the translator boilerplate); the
    # on-disk sidecar is untouched, so retranslate's selection is unaffected.
    if isinstance(metadata, dict) and metadata.get("description"):
        metadata["description"] = clean_check_description(
            metadata["description"], metadata.get("short_description", ""))
    return {"name": name, "metadata": metadata, "star_code": star_code}


def checks_status(checks_dir: str | Path, check_source_names: list[str]) -> dict[str, Any]:
    """Translation progress for the check batch: of the dumped source names
    (the universe), which are already stored. `check_source_names` are the
    flat check names (e.g. 'fileinfo', 'http')."""
    stored = {c["name"] for c in list_checks(checks_dir)}
    missing = sorted(n for n in check_source_names if n not in stored)
    return {"total": len(check_source_names), "translated": len(check_source_names) - len(missing), "missing": missing}
