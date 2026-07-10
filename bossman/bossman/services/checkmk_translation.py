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
from typing import Any

import yaml

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
# Checkmk check → read-only Starlark check module

You are translating a Checkmk **check** (a monitor), NOT a state-changing
Ansible module. The module must be READ-ONLY: it gathers data on the host and
reports a verdict — it never mutates the system (never pass mutates=True,
never call ctx.file_write).

## What to produce

`def main(ctx, params):` that

1. Gathers the same data the Checkmk check consumes, but ON THE HOST via ctx.*
   (the Checkmk *agent plugin*'s job). E.g. run the probe command with
   ctx.run([...]) (mutates=False), or read files with ctx.file_read / ctx.stat.
2. Applies the check's threshold logic. Warn/crit levels arrive in `params`
   (use params.get with the Checkmk default). Compare the measured value.
3. Returns the verdict — NEVER changed=True:

    return {
        "changed": False,
        "msg": "<one-line summary, Checkmk-style, e.g. 'Size: 1.2 MB, Age: 5 m'>",
        "data": {
            "state": "OK",              # one of: OK, WARN, CRIT, UNKNOWN
            "metrics": {"size": 1234, "age": 300},   # perfdata: name -> number
            "details": "",              # optional extra lines
        },
    }

## State rules

- Compute state from the measured value against the params levels:
  upper levels -> WARN if value >= warn, CRIT if value >= crit;
  lower levels -> WARN if value <= warn, CRIT if value <= crit.
- If data cannot be gathered (command missing, file absent when it must
  exist), return state "UNKNOWN" with a msg explaining why — do NOT fail()
  for an expected "not found" the check itself would report as a state.
- `metrics` values MUST be plain numbers (int/float), never strings.

## Example (complete, contract-correct — a file age/size check)

    def main(ctx, params):
        path = params["path"]
        warn_size = params.get("size_warn")
        crit_size = params.get("size_crit")
        st = ctx.stat(path)
        if st == None or not st.get("exists"):
            return {"changed": False, "msg": "File not found: " + path,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        size = st.get("size", 0)
        state = "OK"
        if crit_size != None and size >= crit_size:
            state = "CRIT"
        elif warn_size != None and size >= warn_size:
            state = "WARN"
        return {
            "changed": False,
            "msg": "Size: %d bytes" % size,
            "data": {"state": state, "metrics": {"size": size}, "details": ""},
        }

Keep it focused (typically 40-140 lines). Reproduce the check's core
behavior and thresholds; skip discovery/clustering/SNMP-only paths — this is
a single-service on-host probe.
"""


def build_checkmk_metadata_yaml(record: dict[str, Any]) -> str:
    """Catalog metadata for a translated check module. Like the Ansible
    build_metadata_yaml but always read-only (writes: false) and marks the
    module as a check so the UI/agent can treat its `data.state`/`data.metrics`
    as a monitoring result."""
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
    }
    examples = record.get("examples")
    if examples:
        meta["examples"] = examples
    return yaml.safe_dump(meta, sort_keys=False, allow_unicode=True, width=100)


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
        "- Starlark is NOT Python: NEVER `is`/`is not` (use `== None`), no try/except/raise (fail()), "
        "no imports, no classes, no f-strings, no regex, no lambda. Use d.get(k) for optional keys.\n"
        "- Gather data ONLY through ctx.* builtins; map warn/crit from params."
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
