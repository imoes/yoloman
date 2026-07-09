"""NestedText front-end for the plan engine (Block NT). A NestedText
playbook parses to the *same* Plan/Chunk/PlanStep structures as a YAML plan
(see plan_loader.build_plan_from_raw) — so the whole engine, when_eval,
substitution, and the JSON-in/JSON-out module contract below the loader are
reused unchanged. This module only swaps the surface syntax.

Why NestedText: it has NO type inference, NO quoting, NO escaping — every
leaf is a plain string. That kills YAML's "Norway problem" (no → false),
its number/version coercion, and its quoting hell (e.g. a file mode `0755`
needs no quotes here). The cost is that scalars arrive as strings; we
therefore coerce ONLY the handful of fields the plan schema defines as
booleans (`check_mode`, a param's `required`). We deliberately do NOT
guess types by value anywhere else — doing so would reimport exactly the
ambiguity NestedText exists to remove. Module-argument scalars stay strings
and are coerced at the typed module boundary on the agent (the same place
Ansible coerces its own always-stringly Jinja output).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import nestedtext

from bossman.services.plan_loader import Plan, PlanError, build_plan_from_raw

# NestedText leaf values a human would write for a boolean. Accepted
# case-insensitively for the schema's own boolean fields only.
_TRUE = {"true", "yes", "on", "1"}
_FALSE = {"false", "no", "off", "0"}


def _coerce_bool(value: Any) -> Any:
    """Coerce a NestedText string to bool for a field the schema defines as
    boolean. A real bool (shouldn't occur from NestedText, but harmless) is
    passed through; an unrecognized string is left untouched so the
    downstream validator raises a clear, field-named error."""
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        low = value.strip().lower()
        if low in _TRUE:
            return True
        if low in _FALSE:
            return False
    return value


def _coerce_step(step: Any) -> Any:
    if isinstance(step, dict) and "check_mode" in step:
        step = {**step, "check_mode": _coerce_bool(step["check_mode"])}
    return step


def _coerce_plan_raw(raw: Any) -> Any:
    """Targeted, schema-driven coercion of the all-strings NestedText mapping
    into the shape build_plan_from_raw expects. Only booleans defined by the
    plan schema are touched; every other value stays a string."""
    if not isinstance(raw, dict):
        return raw
    out = dict(raw)

    params = out.get("params")
    if isinstance(params, dict):
        out["params"] = {
            pname: ({**spec, "required": _coerce_bool(spec["required"])} if isinstance(spec, dict) and "required" in spec else spec)
            for pname, spec in params.items()
        }

    if isinstance(out.get("steps"), list):
        out["steps"] = [_coerce_step(s) for s in out["steps"]]

    if isinstance(out.get("chunks"), list):
        chunks = []
        for c in out["chunks"]:
            if isinstance(c, dict) and isinstance(c.get("steps"), list):
                c = {**c, "steps": [_coerce_step(s) for s in c["steps"]]}
            chunks.append(c)
        out["chunks"] = chunks

    if "final_handler" in out:
        out["final_handler"] = _coerce_step(out["final_handler"])

    return out


def parse_plan_nt(data: bytes | str, source_path: Path) -> Plan:
    """Parse a NestedText plan file into a Plan (identical structure to a
    YAML plan). Raises PlanError on malformed NestedText or a schema
    violation."""
    try:
        raw = nestedtext.loads(data.decode() if isinstance(data, bytes) else data, top="dict")
    except nestedtext.NestedTextError as exc:
        raise PlanError(f"{source_path}: invalid NestedText: {exc}") from exc
    if not isinstance(raw, dict):
        raise PlanError(f"{source_path}: plan file must be a NestedText mapping")
    return build_plan_from_raw(_coerce_plan_raw(raw), source_path)


def load_plan_file_nt(path: str | Path) -> Plan:
    """Read and parse a .nt plan file from disk."""
    p = Path(path)
    return parse_plan_nt(p.read_bytes(), p)
