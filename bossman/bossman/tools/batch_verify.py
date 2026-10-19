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


#: `{% for k, v in X | dict2items %}` — two loop variables over dict2items. dict2items yields `{key:, value:}`
#: objects, and unpacking one into two names gives the FIELD NAMES: measured with the agent's engine, every entry
#: renders as the literal `key = value` (postfix: "unused parameter: key=value" in a role's main.cf). The Ansible
#: idiom is `for item in X | dict2items` + item.key/item.value; `X | dictsort` yields the pairs themselves.
_DICT2ITEMS_UNPACK = re.compile(r"(\{%-?\s*for\s+\w+\s*,\s*\w+\s+in\s+[^%]*?)\|\s*dict2items\b")


def fix_dict2items_unpack(template: str) -> str:
    """Rewrite each two-variable loop over `| dict2items` to `| dictsort` (same pairs, sorted by key)."""
    prev = None
    while prev != template:          # a line may hold more than one such loop
        prev = template
        template = _DICT2ITEMS_UNPACK.sub(lambda m: m.group(1) + "| dictsort", template)
    return template


_EXPR = re.compile(r"(\{\{.*?\}\}|\{%.*?%\})", re.S)


def null_safe_objects(template: str, schema: dict) -> tuple[str, list[str]]:
    """Make attribute access on an OBJECT field without a default safe for the agent's engine.

    gonja fails on `{{ pve.auth_url }}` when `pve` is unset ("Can't use Getitem on None") and on `x.items()`
    ("'items' is not callable") — jinja2's ChainableUndefined, which the pipeline checks with, renders both as empty,
    so 14 reachable templates passed the pipeline and could not be rendered with their own defaults (stage 5).
    Inside expressions only: `V.attr` → `(V | default({})).attr`, `V.items()` → `(V | default({})) | dictsort`.
    Returns (template, fields rewritten)."""
    names = [k for k, v in (schema or {}).items()
             if isinstance(v, dict) and v.get("type") == "object" and v.get("default") is None
             and re.fullmatch(r"[A-Za-z_]\w*", k)]
    touched: list[str] = []

    def chain(m: re.Match) -> str:
        # `a.b.c` → `((a | default({})).b | default({})).c` — every level but the last may be unset
        parts = m.group(0).split(".")
        acc = parts[0]
        for part in parts[1:-1]:
            acc = f"({acc} | default({{}})).{part}"
        return f"({acc} | default({{}})).{parts[-1]}"

    def fix(expr: str) -> str:
        for n in names:
            new = re.sub(r"(?<![\w.(])" + n + r"((?:\.[A-Za-z_]\w*)*)\.items\(\)",
                         lambda m: (chain(re.match(r".*", n + m.group(1))) if m.group(1) else n)
                         .join(["(", " | default({})) | dictsort"]) if m.group(1) else f"({n} | default({{}})) | dictsort",
                         expr)
            new = re.sub(r"(?<![\w.(])" + n + r"(?:\.(?!items\b)[A-Za-z_]\w*)+", chain, new)
            if new != expr and n not in touched:
                touched.append(n)
            expr = new
        return expr

    return _EXPR.sub(lambda m: fix(m.group(0)), template), touched


def verify_template(template: str, schema: dict, sample: dict | None = None) -> list[str]:
    """HARD errors only: the schema contract, and template constructs measured to render wrong.
    Use warn_template for heuristics."""
    problems = verify_template_schema(schema)
    if _DICT2ITEMS_UNPACK.search(template or ""):
        problems.append("two loop variables over `| dict2items` render the literal `key = value` — "
                        "use `| dictsort` (or one variable and item.key/item.value)")
    return problems


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
