"""Can this host's platform produce a check's data at all? — Checkmk's discovery
gate, ported.

Checkmk never asks a plugin whether it applies. It asks whether the plugin's
SECTION is in the data fetched from the host, and only then runs discovery
(cmk-check-engine .../discovery/_discover/services.py):

    _find_host_plugins(...) = {
        name for (name, sections) in preliminary_candidates
        if any(section in available_parsed_sections for section in sections)
    }

We can't fetch Checkmk sections — our agent is a different program — but the
question "could a Linux host ever emit this section" is a static fact of the
Checkmk source, extracted by scripts/extract_checkmk_sections.py into
configs/checkmk_sections.json. This module answers it.

Why it was needed: discovery on a plain Debian VM offered aix_hacmp_services,
citrix_sessions, mssql_instance and vms_cpu (OpenVMS). The reason is not the
gate we had but what it trusts — the translated Starlark checks FABRICATE their
section instead of reporting its absence. aix_hacmp_services runs `ps -ef`, finds
no HACMP subsystem, and then appends ("clstrmgrES", "inoperative") anyway, so
discovery yields items and the probe grades them. No behavioural gate can rescue
that; the platform question has to be asked before the check gets a vote.

Deliberately NOT a whitelist of "checks that work on Linux". The translations
sometimes re-target a check onto different commands, so the metadata can be
wrong about OUR check of the same name. Hence three outcomes, not two, and the
caller only drops the certain ones.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

# Platform tags as the extractor writes them (from the agent script's suffix).
# `linux` covers every distro; our facts only distinguish families.
_OS_TAG = "os:"
_PLUGIN_TAGS = ("plugin:",)
_NEVER_AN_AGENT_HOST = ("special:",)
_WINDOWS_TAGS = ("winplugin:", "os:windows")


@lru_cache(maxsize=4)
def _load(path: str) -> dict[str, Any]:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        # No metadata file → every check is "unknown", i.e. nothing is dropped.
        # A missing data file must not silently narrow discovery.
        return {}


def platform_of(facts: dict[str, Any] | None) -> str:
    """The Checkmk agent platform this host would run, from the agent's facts.

    Everything Linux-ish is `linux` — Checkmk ships ONE Linux agent, so a Debian
    and a RHEL host have exactly the same section inventory.
    """
    os_facts = ((facts or {}).get("os") or {}) if isinstance(facts, dict) else {}
    ident = str(os_facts.get("id") or "").lower()
    kernel = str(os_facts.get("kernel") or "").lower()
    if ident in {"windows"} or "windows" in str(os_facts.get("distribution") or "").lower():
        return "windows"
    for name in ("aix", "solaris", "sunos", "freebsd", "openbsd", "netbsd", "hpux", "darwin", "macos"):
        if name in ident or name in kernel:
            return {"sunos": "solaris", "darwin": "macosx", "macos": "macosx"}.get(name, name)
    return "linux"


def verdict(check_name: str, platform: str, sections_path: str) -> str:
    """One of:

    "possible"   — a section of this check is emitted by that platform's agent,
                   or by an OPTIONAL agent plugin for it (mk_postgres and friends).
                   Optional counts as possible: whether the app is installed is
                   exactly what discovery is for.
    "impossible" — the check's sections are known, and every producer of them is
                   another OS's agent, a Windows plugin, or a special agent. No
                   Linux host can ever satisfy it.
    "unknown"    — no metadata, or sections with no known producer. Never dropped.
    """
    data = _load(sections_path)
    checks = data.get("checks") or {}
    producers = data.get("producers") or {}
    sections = checks.get(check_name)
    if not sections:
        return "unknown"

    tags: set[str] = set()
    for section in sections:
        tags.update(producers.get(section) or [])
    if not tags:
        return "unknown"

    if f"{_OS_TAG}{platform}" in tags or any(t.startswith(_PLUGIN_TAGS) for t in tags):
        return "possible"
    foreign = all(
        t.startswith(_NEVER_AN_AGENT_HOST) or t in _WINDOWS_TAGS or t.startswith(_WINDOWS_TAGS) or t.startswith(_OS_TAG)
        for t in tags
    )
    return "impossible" if foreign else "unknown"


def impossible_checks(names: list[str], platform: str, sections_path: str) -> set[str]:
    """The subset of `names` this platform can never satisfy."""
    return {n for n in names if verdict(n, platform, sections_path) == "impossible"}
