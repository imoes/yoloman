"""Checkmk-check → Starlark translation (Block G9): the check-oriented
counterpart of services/starlark_translation.py.

A Checkmk check plugin (parse a raw agent section → discover services →
`check(item, params, section)` yielding Result(state)/Metric) has no place
in the agent's Ansible-module runtime, which only knows
`def main(ctx, params) -> {changed, msg}`. So a check is translated into a
**read-only** Starlark module that gathers the same data on the host itself
(the way Checkmk's *agent plugin* does) and applies the check logic,
returning the monitoring verdict in `data`:

    {"changed": False, "msg": <summary>,
     "data": {"state": "OK"|"WARN"|"CRIT"|"UNKNOWN",
              "metrics": {<name>: <number>, ...},
              "details": <optional multi-line str>}}

This satisfies the existing starlark-check validator (same main/ctx shape,
same required keys) and rides the same MCP pipeline, validator and library
as the Ansible modules — only the prompt/contract and the metadata's
`writes: false` differ. Bossman already ingests agent-reported check state
(poller), so `data.state`/`data.metrics` slot into the existing monitoring
path without a new agent runtime.
"""

from __future__ import annotations

import json
import re
from typing import Any

import nestedtext

from bossman.services.starlark_translation import (  # reuse the shared, tested helpers
    SOURCE_CHAR_BUDGET,
    extract_star_code,  # noqa: F401 — re-exported for the driver
    normalize_starlark,  # noqa: F401
)

# The check-module target shape, layered on top of the base Starlark language
# contract (module_contract, injected by the caller). Kept prose-light and
# example-led — the model already gets the language rules from the base
# contract; this only teaches the read-only monitoring return shape.
CHECK_CONTRACT_ADDENDUM = """\
# Checkmk check → read-only Starlark check module (with discovery)

You are translating a Checkmk **check** (a monitor), NOT a state-changing
Ansible module. The module must be READ-ONLY: it gathers data on the host and
reports a verdict — it never mutates the system (never pass mutates=True,
never call ctx.file_write).

JSON IS AVAILABLE HERE (unlike the base contract's note): `json.decode(s)`
returns the value parsed from a JSON string and `json.encode(v)` returns a
JSON string. Checkmk checks often parse JSON agent output — use
`json.decode(res.stdout)` instead of hand-parsing. (Still no `re`, no `os`,
no imports.)

A Checkmk check has TWO parts you must reproduce, both inside one
`def main(ctx, params):`, selected by whether `params.get("_discover")` is set:

## 1. DISCOVERY MODE  —  when `params.get("_discover")` is true

Reproduce the check's Checkmk `discovery_function`: gather the on-host data
and ENUMERATE the items this host actually has, each with the metric names it
exposes. (Checkmk discovery yields one Service per item — one per filesystem
for df, one per file for fileinfo, ONE PER SENSOR for ipmi, and each item's
metrics are discovered with it.) Return:

    return {
        "changed": False,
        "msg": "discovered N items",
        "data": {"discovery": [
            {"item": "<item name>",            # "" for a single-service check
             "params": {<suggested default params for this item>},
             "metrics": ["<metric name>", ...]},   # the perfdata this item yields
            ...
        ]},
    }

If nothing is found the check does not apply to this host -> return an empty
`discovery` list. A single-service check (no per-item breakdown, e.g. uptime,
mem) returns exactly one entry with item "".

## 2. CHECK MODE  —  otherwise (the normal path)

Check ONE item — `params.get("item", "")` names which one (from discovery;
"" for a single-service check). Gather that item's data on-host via ctx.*
(run the probe with ctx.run([...], mutates=False), or ctx.file_read /
ctx.stat), apply the threshold logic (warn/crit arrive in `params`, use
params.get with the Checkmk default), and return the verdict — NEVER
changed=True:

    return {
        "changed": False,
        "msg": "<one-line summary, Checkmk-style, e.g. 'Size: 1.2 MB, Age: 5 m'>",
        "data": {
            "state": "OK",                          # OK | WARN | CRIT | UNKNOWN
            "metrics": {"size": 1234, "age": 300},  # perfdata: name -> number
            "details": "",
        },
    }

## State rules

- upper levels -> WARN if value >= warn, CRIT if value >= crit;
  lower levels -> WARN if value <= warn, CRIT if value <= crit.
- Data ungatherable / item gone -> state "UNKNOWN" with an explaining msg; do
  NOT fail() for an expected "not found" the check reports as a state.
- `metrics` values MUST be plain numbers (int/float), never strings.

## Example (complete — a per-mount filesystem check, both modes)

    def main(ctx, params):
        if params.get("_discover"):
            res = ctx.run(["df", "-PkT"], mutates=False)
            out = []
            for line in res.stdout.splitlines()[1:]:
                f = line.split()
                if len(f) < 7:
                    continue
                mount = f[6]
                out.append({"item": mount, "params": {"warn": 80, "crit": 90},
                            "metrics": ["used_percent"]})
            return {"changed": False, "msg": "discovered %d filesystems" % len(out),
                    "data": {"discovery": out}}
        item = params.get("item", "")
        res = ctx.run(["df", "-PkT", item], mutates=False)
        lines = res.stdout.splitlines()
        if len(lines) < 2:
            return {"changed": False, "msg": "no such mount: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        f = lines[1].split()
        used = int(f[5].rstrip("%")) if f[5].rstrip("%").isdigit() else 0
        warn = params.get("warn", 80)
        crit = params.get("crit", 90)
        state = "CRIT" if used >= crit else ("WARN" if used >= warn else "OK")
        return {"changed": False, "msg": "%s %d%% used" % (item, used),
                "data": {"state": state, "metrics": {"used_percent": used}, "details": ""}}

Keep it focused (typically 50-160 lines). Reproduce the check's discovery +
core threshold logic; skip only clustering / cluster-section paths.

## GET THE DATA SOURCE RIGHT — never wrap Checkmk

You are translating the plugin to run on OUR agent, which does NOT have Checkmk
installed. NEVER run `cmk`, `checkmk`, `check_mk_agent`, read /var/lib/check_mk*
or /omd/, or `echo` a fabricated `<<<section>>>` — a check that does any of
these is worthless (it can never get data here) and will be rejected. Instead,
read the SAME underlying source the Checkmk plugin/agent reads:

- SNMP check (the source uses SNMPTree/OIDEnd/SimpleSNMPSection or literal OIDs
  like ".1.3.6.1.4.1.…"): translate it as an SNMP check. Walk the OIDs from the
  source with `ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
  "-On", params.get("host", "localhost"), "<base-OID>"], mutates=False)` (or
  snmpget for a scalar), then parse `res.stdout` lines ("<OID> = <TYPE>: <value>")
  exactly as the source maps them. Add `host` and `community` params.
- Agent-section check (source parses `string_table` from an AgentSection): read
  the REAL host source that the Checkmk agent plugin would run — the actual file
  (/proc, /sys, a config) or CLI (ss, ps, systemctl, lsblk, ...). Look at the
  agent plugin's shell if referenced; otherwise reproduce the same data with a
  standard Linux command. Never assume a Checkmk agent is present.

## MAKE IT CONFIGURABLE — expose params with Checkmk defaults

The check MUST be configurable. Read `params.get(...)` for every operator knob:
- per-item checks: `item = params.get("item", "")` (the instance to check).
- thresholds: `params.get("warn", <default>)` / `params.get("crit", <default>)`
  (or `params.get("levels", (<warn>, <crit>))`) using the Checkmk defaults from
  the source. Grade OK/WARN/CRIT against them. Do not hardcode thresholds.

## STARLARK IS NOT PYTHON — these Python constructs DO NOT PARSE

Every one of the following is a hard syntax/name error in Starlark. Do not emit
them even though the source you are translating is Python. Rewrite as shown:

- NO `try:` / `except:` / `finally:` / `raise` — Starlark has no exceptions.
  Instead GUARD before the risky operation:
    WRONG:  try: v = int(x)
            except: v = 0
    RIGHT:  v = int(x) if x.isdigit() else 0
    WRONG:  try: d = json.decode(res.stdout)
            except: return {...UNKNOWN...}
    RIGHT:  if not res.stdout: return {...UNKNOWN...}
            d = json.decode(res.stdout)   # the agent output is well-formed
- NO `nonlocal` / `global` — you cannot reassign a name from an enclosing or
  module scope. Accumulate via a mutable object instead, or return values:
    WRONG:  total = 0
            def add(n): nonlocal total; total += n
    RIGHT:  acc = {"total": 0}          # mutating a dict/list is allowed
            def add(n): acc["total"] += n
- NO `while` loops (use `for ... in`), NO `class`, NO `lambda`, NO f-strings
  (use `"%s" % x` or `"...".format(...)`), NO `import`, NO `re`, NO `is`/`is not`
  (use `== None` / `!= None`), NO comprehension `if` with walrus, NO `assert`.
- Every CONSTANT/name you reference (e.g. a metrics map) MUST be DEFINED at the
  module top level or bound before use — a name defined only inside an `if`
  branch and used elsewhere is `undefined:` at runtime. Define maps at top level.
- List/dict comprehensions and `for` loops ARE supported; use them freely.
"""


# A description is "rich" (already generated by the describe pass) once it
# carries our structured markdown headings — used to skip re-describing.
DESCRIPTION_MARKER = "## What it monitors"

# The fixed top-level taxonomy the describe pass sorts each check into (1444
# checks need grouping in the UI). Checkmk-style topics, kept short and stable.
CHECK_CATEGORIES = [
    "Storage",
    "Network",
    "Operating System",
    "Hardware & Sensors",
    "Applications",
    "Database",
    "Virtualization & Cloud",
    "Backup",
    "Security",
    "Middleware & Messaging",
    "Printers",
    "Environment & Power",
    "Other",
]


def build_describe_messages(name: str, short_description: str, options: dict[str, Any], star_code: str) -> list[dict[str, str]]:
    """Prompt to document ONE translated check in structured Markdown, for both
    a human operator (the UI's expandable check detail) and the AI (MCP context
    when it reasons about monitoring). The description is derived from what the
    check ACTUALLY does — its translated Starlark — not from marketing prose."""
    system = (
        "You write concise, accurate documentation for a monitoring check, for both a human "
        "operator and an AI assistant. You are given the check's translated Starlark source "
        "(the ground truth of its behavior) plus its name and parameters.\n\n"
        "Output ONLY the following, no preamble, no code fences around the whole answer.\n\n"
        "FIRST LINE, exactly: `Category: <X>` where <X> is the single best fit from this list "
        f"(copy it verbatim): {', '.join(CHECK_CATEGORIES)}.\n\n"
        "THEN a blank line, THEN GitHub-flavored Markdown with EXACTLY these sections, in order:\n\n"
        "## Overview\n"
        "One or two sentences: what this check monitors and why it matters.\n\n"
        "## What it monitors\n"
        "A bullet list of the concrete things it measures/observes on the host.\n\n"
        "## How it works\n"
        "How the data is gathered on-host (which command/file the Starlark runs) and how the "
        "OK/WARN/CRIT verdict is decided. Mention discovery (per-item services) if the check "
        "enumerates items.\n\n"
        "## Parameters\n"
        "A bullet per parameter: `name` (type, default) — what it controls. Write 'None.' if there "
        "are no parameters.\n\n"
        "## States\n"
        "When the check reports OK, WARN, CRIT, and UNKNOWN.\n\n"
        "## Metrics\n"
        "A bullet per emitted metric: `name` — what it measures and its unit. Write 'None.' if it "
        "emits no metrics.\n\n"
        "Be factual and specific to THIS check — never invent behavior not present in the source. "
        "Do NOT mention Checkmk, 'translated', or the check's origin/provenance — describe it as a "
        "native yolo-man monitoring check, in the present tense. "
        "Keep it tight (roughly 120-250 words)."
    )
    code = star_code if len(star_code) <= SOURCE_CHAR_BUDGET else star_code[:SOURCE_CHAR_BUDGET]
    user = (
        f"Document this check.\n\n"
        f"Name: {name}\n"
        f"Short description: {short_description}\n\n"
        f"Parameters (argspec): {json.dumps(options or {}, indent=1, sort_keys=True)[:4000]}\n\n"
        f"Translated Starlark source (its real behavior):\n```python\n{code}\n```"
    )
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]


_PARAM_GET = re.compile(r'params\.get\(\s*["\']([a-zA-Z_][a-zA-Z0-9_]*)["\']\s*(?:,\s*([^)]*))?\)')


def _derive_options_from_star(star: str) -> dict[str, Any]:
    """Build a baseline options schema from a check's `params.get("k", default)`
    calls, so a translated check is CONFIGURABLE even when the dumped Checkmk
    ruleset carried no argspec (the common case — nearly all bulk checks). Type
    is inferred from the default literal; the discovery-internal `_discover`
    flag and the auto-populated `item` are skipped (item comes from discovery,
    not an operator field)."""
    opts: dict[str, Any] = {}
    for m in _PARAM_GET.finditer(star):
        key, default = m.group(1), (m.group(2) or "").strip()
        if key in ("_discover", "item") or key in opts:
            continue
        typ, dflt = "string", None
        if default:
            if default in ("True", "False"):
                typ, dflt = "bool", default == "True"
            elif re.fullmatch(r"-?\d+", default):
                typ, dflt = "number", int(default)
            elif re.fullmatch(r"-?\d+\.\d+", default):
                typ, dflt = "number", float(default)
            elif default[:1] in "([":
                typ = "list"  # e.g. levels=(80, 90) — a warn/crit pair
            elif default[:1] in "\"'":
                dflt = default.strip("\"'")
        spec: dict[str, Any] = {"type": typ}
        if dflt is not None:
            spec["default"] = dflt
        spec["description"] = f"{key} (from the check's parameters)."
        opts[key] = spec
    return opts


_SNMP_SRC_RE = re.compile(
    r"SNMPTree|snmp_section|register\.snmp|OIDEnd|OIDBytes|OIDCached|SNMPBackend|\bdetect\s*=\s*(all_of|any_of|contains|equals|exists|startswith)"
)
_SNMP_STAR_RE = re.compile(r"snmpwalk|snmp_get|snmp_walk|ctx\.snmp")


def detect_check_execution(source_py: str = "", star_code: str = "") -> str:
    """Deterministic axis of a check's execution kind: 'snmp' when the source
    is an SNMP section (SNMPTree/detect/…) or the translated Starlark actually
    walks SNMP; otherwise 'local' (runs a command on the host). The finer
    'local' vs 'service' (configurable, fileinfo-style) split is NOT decidable
    here — that is the LLM classifier's job (scripts/classify_check_execution.py),
    whose side registry overrides this default. SNMP is 100% deterministic and
    needs no model, so we settle it here for free."""
    if _SNMP_SRC_RE.search(source_py or "") or _SNMP_STAR_RE.search(star_code or ""):
        return "snmp"
    return "local"


def build_checkmk_metadata_nt(record: dict[str, Any], star_code: str = "") -> str:
    """Catalog metadata for a translated check module, as NestedText (project
    convention — no YAML). Always read-only (writes: false) and marked kind:
    check so the UI/agent treat its `data.state`/`data.metrics` as a
    monitoring result. Also carries `execution` (snmp|local|service) so the UI
    can group checks by how they run (see detect_check_execution)."""
    doc = record.get("doc") or {}
    options: dict[str, Any] = {}
    for name, spec in sorted((doc.get("options") or {}).items()):
        opt: dict[str, Any] = {"type": spec.get("type", "str")}
        if spec.get("required"):
            opt["required"] = True
        if spec.get("default") is not None:
            opt["default"] = spec["default"]
        if spec.get("choices"):
            opt["choices"] = spec["choices"]
        desc = spec.get("description")
        if isinstance(desc, list):
            desc = " ".join(str(d) for d in desc)
        if desc:
            opt["description"] = str(desc)
        options[name] = opt

    # The dumped Checkmk ruleset rarely carries an argspec, so fall back to the
    # knobs the translated Starlark actually reads — otherwise the check ships
    # non-configurable (empty options), the catalog-wide defect we're fixing.
    if not options and star_code:
        options = _derive_options_from_star(star_code)

    description = doc.get("description")
    if isinstance(description, list):
        description = " ".join(str(d) for d in description)

    meta = {
        "name": record["name"],
        "fqcn": record["fqcn"],
        "collection": record["collection"],
        "short_description": record.get("short_description") or doc.get("short_description") or "",
        "description": description or "",
        "options": options,
        "writes": False,          # a check never mutates
        "runtime": "starlark",
        "source": "translated",
        "kind": "check",          # distinguishes a monitor from an action module
        # how the check runs: snmp (SNMP walk) | local (on-host command) |
        # service (configurable, fileinfo-style). SNMP settled deterministically;
        # local↔service is refined by the LLM classifier's side registry.
        "execution": detect_check_execution(record.get("source_py", ""), star_code),
    }
    examples = record.get("examples")
    if examples:
        meta["examples"] = examples
    # NestedText: all leaves must be strings — default=str coerces the bool
    # (writes) and any numeric defaults; nested option dicts are preserved.
    return nestedtext.dumps(meta, default=str)


def build_checkmk_messages(contract: str, record: dict[str, Any]) -> list[dict[str, str]]:
    """The initial prompt for translating a Checkmk check: base Starlark
    language contract + the check-module addendum as the system prompt, the
    per-check source as the user message."""
    doc = record.get("doc") or {}
    source = record.get("source_py") or ""
    truncated = len(source) > SOURCE_CHAR_BUDGET
    if truncated:
        source = source[:SOURCE_CHAR_BUDGET]

    system = (
        "You translate Checkmk check plugins into read-only Starlark check modules "
        "for the yolo-man agent.\n"
        "Follow the base language contract EXACTLY:\n\n"
        f"{contract}\n\n"
        f"{CHECK_CONTRACT_ADDENDUM}\n\n"
        "Rules for your answer:\n"
        "- Output ONLY the Starlark module code — no prose, no JSON. One ```python fenced block.\n"
        "- The module is READ-ONLY: never mutates=True, never ctx.file_write, always changed=False.\n"
        "- Starlark is NOT Python (see the addendum's forbidden-constructs block): NO try/except/"
        "finally/raise, NO nonlocal/global, NO while/class/lambda/f-strings/imports/regex, NO `is`/"
        "`is not` (use `== None`). Guard instead of try; use d.get(k) for optional keys; define every "
        "constant at module top level.\n"
        "- Gather data ONLY through ctx.* builtins; map warn/crit from params.\n\n"
        # qwen79b self-reported that try/except and ** are strong Python priors it
        # emits despite general prohibitions; a final imperative checklist right
        # before output is the format it most reliably obeys (rules-as-checklist,
        # no justification, "output only code").
        "BEFORE YOU OUTPUT, SELF-CHECK EVERY LINE (a violation CRASHES the check in production):\n"
        "[ ] NO try / except / finally / raise  (guard with `if`/defaults instead)\n"
        "[ ] NO `**`  (there is no power operator AND no pow(); use x*x, or a top-level def _pow(b,e))\n"
        "[ ] NO import / from-import\n"
        "[ ] NO f-strings  (use \"%s\" % x or \"{}\".format(x))\n"
        "[ ] NO chained comparison a<=b<=c  (write (a<=b) and (b<=c))\n"
        "[ ] NO `is`/`is not`  (use == None / != None)\n"
        "[ ] The module DEFINES `def main(ctx, params):`\n"
        "OUTPUT ONLY THE CODE."
    )
    user = (
        "Translate this Checkmk check into a read-only Starlark check module.\n\n"
        f"Check: {record['fqcn']}\n"
        f"Short description: {record.get('short_description', '')}\n\n"
        f"Parameters the check accepts (your params dict; use the Checkmk defaults):\n"
        f"{json.dumps(doc.get('options') or {}, indent=1, sort_keys=True)[:6000]}\n\n"
        f"Checkmk check source{' (truncated)' if truncated else ''} — the parse/check logic to reproduce "
        "on-host:\n"
        f"```python\n{source}\n```"
    )
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]
