"""Deterministic output-contract verification for the two LLM batches — the
template qualify pipeline (qualify_packages.py) and the Checkmk check translator
(retranslate_checks.py / _mcp_pipeline.translate_one).

Pure, model-free checks: given an artifact, return a list of contract problems
(empty = OK). This lets the mocked tests (tests/test_batch_verify.py) drive the
pipelines with a canned LLM and assert correctness deterministically, and lets a
batch self-verify each artifact before accepting it.

The contracts encode the bugs we actually hit:
- schema `default` must be a BARE scalar, never a nested {"value": X} object;
- `type` must be canonical (string/number/bool/list/object) — not `boolean`/`integer`;
- list `items` must be a FLAT field->spec map, not JSON-schema {type:object,properties};
- every template variable must exist in values_schema;
- a translated check must pass starlark-check AND be runnable (no cmk/checkmk wrapper).
"""
from __future__ import annotations

import re

# What ParamForm (the consumer) understands. `boolean`/`integer`/`float` are
# common LLM drift and render wrong, so they are flagged.
_CANONICAL_TYPES = {"string", "number", "bool", "list", "object", "secret"}

_VAR_RE = re.compile(r"\{\{-?\s*([a-zA-Z_]\w*)")          # {{ var … }}  → base identifier
# {% for a, b in SRC %} — capture the (possibly multi-) loop-var list and the source.
_FORVAR_RE = re.compile(r"\{%-?\s*for\s+([\w,\s]+?)\s+in\s+")
_FORSRC_RE = re.compile(r"\{%-?\s*for\s+[\w,\s]+?\s+in\s+([a-zA-Z_]\w*)")
_SETVAR_RE = re.compile(r"\{%-?\s*set\s+(\w+)\s*=")       # {% set x = … %} introduces x
_TEMPLATE_BUILTINS = {"loop", "true", "false", "none", "range", "namespace"}


def verify_template_schema(schema: dict) -> list[str]:
    """HARD contract errors on a values_schema (recurses into list `items`) —
    the deterministic, high-confidence checks that break the consumer. Missing
    `type` is a soft warning (grouping/section keys legitimately omit it), see
    warn_template."""
    problems: list[str] = []
    if not isinstance(schema, dict):
        return ["values_schema is not an object"]
    for key, spec in schema.items():
        if not isinstance(spec, dict):
            problems.append(f"{key}: field spec is not an object")
            continue
        default = spec.get("default")
        # A dict default is the `{"value": X}` value-wrapping bug ONLY on a scalar field. A field that is
        # genuinely `type: object` (a free-form key/value map) legitimately defaults to {} — don't flag it.
        if isinstance(default, dict) and spec.get("type") not in ("object", "dict", "map"):
            problems.append(f"{key}: default is an object ({sorted(default)[:3]}) — must be a bare scalar/array")
        t = spec.get("type")
        if t is not None and not isinstance(t, str):
            problems.append(f"{key}: `type` is not a string ({type(t).__name__})")
        elif isinstance(t, str) and t and t not in _CANONICAL_TYPES:
            problems.append(f"{key}: non-canonical type {t!r} (use string/number/bool/list/object)")
        items = spec.get("items")
        if isinstance(items, dict):
            itype = items.get("type")
            if itype == "object" and ("properties" in items or "fields" in items):
                problems.append(f"{key}.items: JSON-schema nesting (type:object+properties/fields) — "
                                f"expected a flat field->spec map")
            elif isinstance(itype, str) and itype in _CANONICAL_TYPES and itype != "object":
                # A list of SCALARS: `items` is a single leaf spec ({type:"string", default:"", …}),
                # not a field->spec map. Validate it as one spec — do NOT recurse, or its own keys
                # (type/default/description) get misread as field names ("field spec is not an object").
                idefault = items.get("default")
                if isinstance(idefault, dict):
                    problems.append(f"{key}.items: default is an object — must be a bare scalar/array")
            else:
                problems += [f"{key}.items.{p}" for p in verify_template_schema(items)]
    return problems


def _loop_vars(template: str) -> set[str]:
    out: set[str] = set()
    for grp in _FORVAR_RE.findall(template):
        out |= {v.strip() for v in grp.split(",") if v.strip()}
    return out


def template_variables(template: str) -> set[str]:
    """Top-level {{ var }} identifiers a template reads, excluding loop-unpacked
    names ({% for a, b in … %}), {% set %} vars, loop sources, and builtins."""
    used = set(_VAR_RE.findall(template)) | set(_FORSRC_RE.findall(template))
    return used - _loop_vars(template) - set(_SETVAR_RE.findall(template)) - _TEMPLATE_BUILTINS


def verify_template(template: str, schema: dict, sample: dict | None = None) -> list[str]:
    """HARD errors only: the schema contract. Use warn_template for heuristics."""
    return verify_template_schema(schema)


def warn_template(template: str, schema: dict, sample: dict | None = None) -> list[str]:
    """SOFT, heuristic warnings (may false-positive on complex templates): fields
    with no `type`, template variables not in the schema (ignoring ones only used
    with a |default filter), and non-defaulted fields missing from sample."""
    warns: list[str] = []
    for k, spec in (schema or {}).items():
        if isinstance(spec, dict) and "type" not in spec:
            warns.append(f"{k}: no `type` (grouping key, or a real omission)")
    keys = set(schema or {})
    # A var used only as `{{ x | default(...) }}` is intentionally optional.
    defaulted = set(re.findall(r"\{\{-?\s*([a-zA-Z_]\w*)\s*\|\s*default\(", template))
    missing = sorted(v for v in template_variables(template) if v not in keys and v not in defaulted)
    if missing:
        warns.append(f"template variables not in values_schema (heuristic): {missing}")
    if sample is not None:
        for k, spec in (schema or {}).items():
            if isinstance(spec, dict) and spec.get("default") is None and k not in sample:
                warns.append(f"{k}: no default and not in sample_values")
    return warns


def verify_check(star: str, validation: dict) -> list[str]:
    """Contract checks on a translated Checkmk check: passed the starlark-check
    gate AND runnable on our agent (no cmk/checkmk/agent-output wrapper)."""
    from bossman.services.checks_library import check_runnable

    problems: list[str] = []
    if not validation.get("ok"):
        errs = validation.get("errors") or []
        msg = errs[0].get("message", "") if errs else validation.get("defect", "")
        problems.append(f"starlark-check failed: {str(msg)[:200]}")
    if not check_runnable(star):
        problems.append("not runnable: wraps cmk/checkmk (or fabricated agent output)")
    return problems
