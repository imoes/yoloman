#!/usr/bin/env python3
"""Extract Checkmk's own discovery inputs from a Checkmk source tree.

Our service discovery had no equivalent of Checkmk's central discovery rule, and
it showed: a plain Debian VM was offered aix_hacmp_services, citrix_sessions,
vms_cpu (OpenVMS!) and ibm_svc_systemstats_iops. Checkmk never asks a plugin
whether it applies — see cmk-check-engine .../discovery/_discover/services.py:

    _find_host_plugins(...) = {
        name for (name, sections) in preliminary_candidates
        if any(section in available_parsed_sections for section in sections)
    }

A plugin is a candidate ONLY IF one of its declared sections is present in the
data actually fetched from the host. Everything else never runs.

We cannot fetch Checkmk sections — our agent is a different program — but both
halves of that rule are static facts in the Checkmk source, so this script lifts
them out:

  1. check plugin -> declared sections
       CheckPlugin(name="x", sections=["y"]) ; sections defaults to [name]
  2. section -> what produces it
       which OS agent script emits `<<<section>>>`, which optional agent plugin
       does, which special agent (datasource program) does, and which sections
       are SNMP-only.

The result (configs/checkmk_sections.json) lets Bossman answer "could this host
possibly produce this check's data" before running anything — the same question
Checkmk answers from the fetched sections.

Usage:  scripts/extract_checkmk_sections.py [/path/to/checkmk] [-o out.json]
"""

from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from pathlib import Path

# OS agents ship as one script per platform; the suffix IS the platform name.
# openvms/hpux/netbsd are in here too — those are exactly the ones whose sections
# were being offered on Linux.
AGENT_SCRIPTS = "check_mk_agent.*"

# `<<<section>>>` / `<<<section:sep(9)>>>` / `<<<section:cached(...)>>>`. Also
# matches the plugin-name form `<<<mssql_counters>>>` inside plugins.
SECTION_RE = re.compile(r"<<<\s*([a-zA-Z0-9_]+)\s*(?::[^>]*)?>>>")

# Special agents rarely write the header themselves. Two indirect forms, both of
# which the first version of this script missed entirely — which is why
# ibm_svc_systemstats had NO known producer and its check kept being offered on a
# Debian VM (where it reads /proc/diskstats and calls it IBM SVC statistics):
#   SectionWriter("ibm_svc_systemstats")     the helper in special_agents/v0_unstable
#   "section_header": "ibm_svc_systemstats"  a command table, as agent_ibmsvc uses
INDIRECT_SECTION_RES = (
    re.compile(r"SectionWriter\(\s*[\"']([a-zA-Z0-9_]+)[\"']"),
    re.compile(r"section_header[\"']?\s*:\s*[\"']([a-zA-Z0-9_]+)[\"']"),
)


def _sections_in(text: str, indirect: bool = False) -> set[str]:
    """Section names a source file emits. `indirect` adds the special-agent forms;
    a computed name (an f-string) is deliberately not guessed at."""
    found = set(SECTION_RE.findall(text))
    if indirect:
        for pattern in INDIRECT_SECTION_RES:
            found.update(pattern.findall(text))
    return found

# Section classes declared in the plugin API. SNMP ones can never come from an
# agent host, so they are recorded separately rather than as producers.
AGENT_SECTION_CLASSES = {"AgentSection", "SimpleSNMPSection", "SNMPSection"}
SNMP_SECTION_CLASSES = {"SimpleSNMPSection", "SNMPSection"}


def _str_of(node: ast.AST) -> str | None:
    """The literal string a keyword holds, if it is a plain literal.

    Section and plugin names in Checkmk are always literals — a computed name
    could not be referenced from a config anyway — so anything else is skipped
    rather than guessed at.
    """
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    # SectionName("x") / CheckPluginName("x") wrappers
    if isinstance(node, ast.Call) and node.args:
        return _str_of(node.args[0])
    return None


def _list_of_str(node: ast.AST) -> list[str]:
    if isinstance(node, (ast.List, ast.Tuple)):
        return [s for s in (_str_of(e) for e in node.elts) if s]
    single = _str_of(node)
    return [single] if single else []


def extract_plugins(root: Path) -> tuple[dict[str, list[str]], set[str], set[str], dict[str, str]]:
    """Walk the plugin sources for the declarations discovery needs.

    Returns (check -> sections, agent-section names, SNMP-only sections,
    raw-section -> parsed-section).

    The last one is not optional. CheckPlugin.sections names PARSED sections, and
    the raw name on the wire is often different: the Linux agent emits
    `<<<df_v2>>>`, declared as AgentSection(name="df_v2", parsed_section_name="df"),
    and the check asks for "df". Without following that indirection, df and the
    NIC checks looked like they had no Linux producer at all — which would have
    dropped the most obviously correct checks on the host.
    """
    checks: dict[str, list[str]] = {}
    agent_sections: set[str] = set()
    snmp_sections: set[str] = set()
    parsed_of: dict[str, str] = {}

    search = [root / "cmk" / "plugins", root / "cmk" / "base" / "legacy_checks"]
    for base in search:
        if not base.is_dir():
            continue
        for path in base.rglob("*.py"):
            try:
                tree = ast.parse(path.read_text(encoding="utf-8"))
            except (OSError, SyntaxError):
                continue
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                func = node.func
                cls = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
                if cls not in {"CheckPlugin", *AGENT_SECTION_CLASSES}:
                    continue
                kw = {k.arg: k.value for k in node.keywords if k.arg}
                name = _str_of(kw["name"]) if "name" in kw else None
                if not name:
                    continue
                if cls == "CheckPlugin":
                    # No `sections=` means the plugin consumes the section that
                    # shares its name — the API's documented default.
                    sections = _list_of_str(kw["sections"]) if "sections" in kw else [name]
                    checks[name] = sections
                else:
                    agent_sections.add(name)
                    if cls in SNMP_SECTION_CLASSES:
                        snmp_sections.add(name)
                    parsed = _str_of(kw["parsed_section_name"]) if "parsed_section_name" in kw else None
                    if parsed:
                        parsed_of[name] = parsed
    return checks, agent_sections, snmp_sections, parsed_of


def extract_legacy_checks(root: Path) -> dict[str, list[str]]:
    """Legacy check_info[] plugins, whose name carries the section as its prefix.

    Names like `ibm_svc_systemstats_iops` are one plugin per SUBCHECK, and the
    section is the part before the subcheck ("ibm_svc_systemstats"). Only the
    longest matching known section counts, so `mem_used` is not misread as
    section `mem`.
    """
    out: dict[str, list[str]] = {}
    base = root / "cmk" / "base" / "legacy_checks"
    if not base.is_dir():
        return out
    for path in base.rglob("*.py"):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for m in re.finditer(r"check_info\[\s*['\"]([a-zA-Z0-9_.]+)['\"]\s*\]", text):
            name = m.group(1)
            out.setdefault(name.replace(".", "_"), [name.split(".")[0]])
    return out


def extract_catalog(root: Path) -> dict[str, str]:
    """check -> Checkmk's own catalog path, from its man page (`catalog: app/postgresql`).

    Not a gate: `os/*` and `app/*` are equally real on a Linux host, and whether
    the app is installed is what discovery is for. It IS the priority list for
    fixing translations — an `app/*` check that reports OK while reading only
    `ps` or /etc/passwd is claiming an application it never found. A check with
    no man page at all (mkevents, cmk_inv) is not a plugin in this version.
    """
    out: dict[str, str] = {}
    for man in root.rglob("checkman/*"):
        if man.is_dir():
            continue
        try:
            for line in man.read_text(encoding="utf-8", errors="replace").splitlines():
                if line.startswith("catalog:"):
                    out[man.name] = line.split(":", 1)[1].strip()
                    break
        except OSError:
            continue
    return out


def extract_producers(root: Path) -> dict[str, set[str]]:
    """section -> the set of things that emit it.

    Producers are named by where they come from, because that is what decides
    availability on a given host:
      "os:linux"      the platform agent emits it natively — always available
      "plugin:mk_foo" an OPTIONAL agent plugin — available only where installed,
                      which is exactly the case a probe can still decide
      "special:foo"   a special agent / datasource program — never an agent host
    """
    producers: dict[str, set[str]] = {}

    def record(section: str, producer: str) -> None:
        producers.setdefault(section, set()).add(producer)

    agents = root / "agents"
    for script in sorted(agents.glob(AGENT_SCRIPTS)):
        if script.is_dir():
            continue
        platform = script.suffix.lstrip(".") or "linux"
        try:
            text = script.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for section in SECTION_RE.findall(text):
            record(section, f"os:{platform}")

    # Optional agent plugins. The Windows tree is kept separate: a Windows-only
    # plugin's section must not make a check a candidate on Linux.
    plugin_dirs: list[tuple[Path, str]] = [
        (agents / "plugins", "plugin"),
        (agents / "windows" / "plugins", "winplugin"),
    ]
    # Since 2.3 most agent plugins live with their family: cmk/plugins/<x>/agents/.
    # Scanning only agents/plugins found 35 files and missed mk_postgres, mk_oracle,
    # mk_docker and the rest — i.e. exactly the optional-app sections.
    for family in sorted((root / "cmk" / "plugins").glob("*/agents")):
        plugin_dirs.append((family, "plugin"))
    for plugdir, tag in plugin_dirs:
        if not plugdir.is_dir():
            continue
        for path in sorted(plugdir.rglob("*")):
            if path.is_dir():
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for section in SECTION_RE.findall(text):
                record(section, f"{tag}:{path.name}")

    # The Windows agent emits its sections from C++ providers, not <<<>>> echoes,
    # so read the section names it registers.
    win = root / "agents" / "wnx" / "src"
    if win.is_dir():
        for path in win.rglob("*.cpp"):
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for section in SECTION_RE.findall(text):
                record(section, "os:windows")

    # Special agents: `cmk/special_agents/agent_<x>.py` fetches from an API and
    # prints sections. A check behind one of these is never satisfied by a host
    # agent, however healthy the host is.
    for special_dir in (root / "cmk" / "special_agents", root / "cmk" / "plugins"):
        if not special_dir.is_dir():
            continue
        for path in special_dir.rglob("agent_*.py"):
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            name = path.stem.removeprefix("agent_")
            for section in _sections_in(text, indirect=True):
                record(section, f"special:{name}")

    return producers


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("checkmk", nargs="?", default=str(Path.home() / "Dev/code/checkmk"))
    ap.add_argument("-o", "--out", default="configs/checkmk_sections.json")
    args = ap.parse_args()

    root = Path(args.checkmk)
    if not (root / "cmk").is_dir():
        print(f"not a checkmk source tree: {root}", file=sys.stderr)
        return 2

    checks, agent_sections, snmp_sections, parsed_of = extract_plugins(root)
    legacy = extract_legacy_checks(root)
    for name, sections in legacy.items():
        checks.setdefault(name, sections)
    catalog = extract_catalog(root)
    producers = extract_producers(root)
    # Re-key producers by PARSED section name, which is what checks ask for.
    # Both keys are kept: a raw name can also be a parsed name elsewhere.
    for raw, parsed in parsed_of.items():
        if raw in producers:
            producers.setdefault(parsed, set()).update(producers[raw])

    payload = {
        "_source": "generated by scripts/extract_checkmk_sections.py from the Checkmk source tree",
        "_rule": "a check is a candidate only if one of its sections is produced for the host's platform "
        "(cmk-check-engine discovery/_discover/services.py::_find_host_plugins)",
        "checks": {k: sorted(v) for k, v in sorted(checks.items())},
        "producers": {k: sorted(v) for k, v in sorted(producers.items())},
        "catalog": dict(sorted(catalog.items())),
        "parsed_section_of": dict(sorted(parsed_of.items())),
        "snmp_sections": sorted(snmp_sections),
        "agent_sections": sorted(agent_sections),
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=1, sort_keys=False) + "\n", encoding="utf-8")

    print(f"checks          {len(checks)}")
    print(f"sections        {len(producers)} with a known producer")
    print(f"  os:linux      {sum(1 for p in producers.values() if 'os:linux' in p)}")
    print(f"  optional plugin {sum(1 for p in producers.values() if any(x.startswith('plugin:') for x in p))}")
    print(f"  special agent {sum(1 for p in producers.values() if any(x.startswith('special:') for x in p))}")
    print(f"snmp sections   {len(snmp_sections)}")
    print(f"catalogued      {len(catalog)} checks have a man page")
    print(f"-> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
