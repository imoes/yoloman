"""Deterministic gates + prompts shared by the enrich PILOT (enrich_templates_pilot.py) and the
production batch (qualify_packages.py). One place so the two never drift.

An enrich call produces TWO artifacts for a package: an enriched, self-documenting `template.j2` and a
`capabilities.json` describing what the package provides/requires (the Lego contract). Both are accepted
ONLY when all five gates pass; otherwise the original is left untouched (the batch cannot break anything).

Gates:
  1. contract  — batch_verify.verify_template: flat schema, canonical types, no object defaults, every
                 template variable present in the schema.
  2. gonja     — render through the Go agent's own engine (the render-check binary), which registers the
                 Ansible filter set. This is what actually runs on a host.
  3. ansible   — render with REAL ansible-core filters under StrictUndefined and an EMPTY context: proves
                 every variable has a default AND only genuine Ansible/Jinja2 filters are used, natively.
  4. fields    — every schema-field name referenced in capabilities.json must exist in schema.json
                 (blocks invented fields like `server.port` for a `server_port` schema key).
  5. vocab     — every capability/backend token must come from configs/capability_vocabulary.json, unless
                 the whole capabilities.json is marked "confidence": "review" for a human to canonicalise.
"""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
from functools import lru_cache
from pathlib import Path

# jinja2 is Ansible's engine; ansible-core is installed, so we load ITS real filter set (no stubs).
from jinja2 import Environment, StrictUndefined, TemplateError, UndefinedError

from bossman.tools._paths import configs_dir, repo_root

_HERE = Path(__file__).resolve()
# parents[2] was the repo root in the container and one level short in a checkout — see _paths.repo_root.
ROOT = repo_root(__file__)
TEMPLATES = configs_dir(__file__) / "config_templates"
VOCAB_PATH = configs_dir(__file__) / "capability_vocabulary.json"

# The delimiters that split the model's single reply into its two artifacts.
T_MARK = "===TEMPLATE==="
C_MARK = "===CAPABILITIES==="


# ---------------------------------------------------------------------------- vocabulary


@lru_cache(maxsize=1)
def vocabulary() -> dict:
    return json.loads(VOCAB_PATH.read_text())


@lru_cache(maxsize=1)
def _vocab_index() -> tuple[dict[str, set[str]], dict[str, list[str]]]:
    """(capability -> allowed backends, backend -> wire-compatible aliases)."""
    v = vocabulary()
    caps = {name: set(spec.get("backends", [])) for name, spec in v["capabilities"].items()}
    aliases = {k: list(vv) for k, vv in v.get("backend_aliases", {}).items() if not k.startswith("_")}
    return caps, aliases


# ---------------------------------------------------------------------------- real Ansible filters


@lru_cache(maxsize=1)
def _ansible_filters() -> dict:
    """The genuine ansible-core filter plugins (core + mathstuff + urls) — no stubs, so gate 3 is honest.
    Falls back to a minimal stub set only if ansible is somehow unimportable."""
    try:
        from ansible.plugins.filter.core import FilterModule as Core
        from ansible.plugins.filter.mathstuff import FilterModule as Math
        from ansible.plugins.filter.urls import FilterModule as Urls

        fs: dict = {}
        for mod in (Core, Math, Urls):
            fs.update(mod().filters())
        return fs
    except Exception:  # noqa: BLE001 — degrade gracefully if ansible isn't present
        import base64 as _b64
        import re as _re

        return {
            "ternary": lambda v, t, f=None: t if v else f,
            "bool": lambda v: str(v).lower() in ("true", "1", "yes", "on"),
            "to_json": lambda v, **k: json.dumps(v),
            "to_nice_json": lambda v, **k: json.dumps(v, indent=4),
            "b64encode": lambda s, **k: _b64.b64encode(str(s).encode()).decode(),
            "regex_replace": lambda s, a, b, *r: _re.sub(a, b, str(s)),
            "quote": lambda s: "'" + str(s) + "'",
        }


# ---------------------------------------------------------------------------- render-check (gonja) binary


@lru_cache(maxsize=1)
def render_check_bin() -> str:
    """Path to the compiled render-check binary (the gonja gate). Build once into a temp path unless
    RENDER_CHECK_BIN points at a prebuilt one."""
    env = os.environ.get("RENDER_CHECK_BIN")
    if env and Path(env).exists():
        return env
    out = str(Path(tempfile.gettempdir()) / "render-check")
    subprocess.run(
        ["go", "build", "-o", out, "./cmd/render-check/"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    )
    return out


# ---------------------------------------------------------------------------- schema normalization (pre-gate 1)

# LLM type drift → the canonical set ParamForm understands (batch_verify._CANONICAL_TYPES).
_TYPE_CANON = {
    "boolean": "bool", "bool": "bool",
    "integer": "number", "int": "number", "float": "number", "number": "number",
    "string": "string", "str": "string", "text": "string",
    "array": "list", "list": "list",
    "dict": "object", "object": "object", "map": "object",
    "secret": "secret",
}


def normalize_schema(schema: dict) -> tuple[dict, bool]:
    """Deterministically fix the mechanical schema drift the enrich LLM does NOT produce and MUST NOT be
    asked to fix (it only emits template.j2 + capabilities.json): non-canonical type names (boolean->bool,
    integer->number) and JSON-schema list nesting (items:{type:object,properties:{…}} -> flat field map).
    Returns (normalized_schema, changed). Pure logic — this is why the batch can't break a curated schema:
    it only canonicalises, never restructures meaning."""
    changed = False

    def norm_spec(spec: object) -> object:
        nonlocal changed
        if not isinstance(spec, dict):
            return spec
        out = dict(spec)
        t = out.get("type")
        if isinstance(t, str) and t in _TYPE_CANON and _TYPE_CANON[t] != t:
            out["type"] = _TYPE_CANON[t]
            changed = True
        items = out.get("items")
        if isinstance(items, dict):
            # Flatten the two JSON-schema nesting conventions to a flat field->spec map:
            # items:{type:object, properties:{X}} and items:{type:object, fields:{X}} -> items:{X}.
            if items.get("type") == "object" and isinstance(items.get("properties"), dict):
                items = items["properties"]
                changed = True
            elif items.get("type") == "object" and isinstance(items.get("fields"), dict):
                items = items["fields"]
                changed = True
            it = items.get("type") if isinstance(items, dict) else None
            if isinstance(it, str) and it in _TYPE_CANON:
                # scalar-list leaf spec ({type:"string"}): canonicalise its own type, don't descend.
                out["items"] = norm_spec(items)
            else:
                # flat field->spec map: normalise each field spec.
                out["items"] = {k: norm_spec(v) for k, v in items.items()} if isinstance(items, dict) else items
        return out

    normalized = {k: norm_spec(v) for k, v in (schema or {}).items()}
    return normalized, changed


# ---------------------------------------------------------------------------- gate 1: contract


def gate_contract(template: str, schema: dict) -> list[str]:
    from batch_verify import verify_template  # same scripts/ dir

    return [f"contract: {p}" for p in verify_template(template, schema)]


# ---------------------------------------------------------------------------- gate 2: gonja render


def gate_gonja(template: str, sample: dict) -> list[str]:
    with tempfile.TemporaryDirectory() as td:
        tp = Path(td) / "t.j2"
        vp = Path(td) / "v.json"
        tp.write_text(template)
        vp.write_text(json.dumps(sample or {}))
        proc = subprocess.run(
            [render_check_bin(), "-template", str(tp), "-values", str(vp)],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            return [f"gonja: {proc.stderr.strip()[:300]}"]
    return []


# ---------------------------------------------------------------------------- gate 3: real ansible


def gate_ansible_empty(template: str) -> list[str]:
    """Render with the real ansible filters under StrictUndefined and NO variables set. A pass proves
    both 'every variable has a default' and 'only genuine Ansible filters are used'."""
    env = Environment(undefined=StrictUndefined, autoescape=False)  # noqa: S701 — config text, not HTML
    env.filters.update(_ansible_filters())
    try:
        env.from_string(template).render({})
    except UndefinedError as exc:
        return [f"ansible: a variable lacks a default (undefined with empty context): {exc}"]
    except TemplateError as exc:
        return [f"ansible: does not parse/render: {exc}"]
    except Exception as exc:  # noqa: BLE001 — a filter called with bad args is a real, fixable fault
        return [f"ansible: does not parse/render: {type(exc).__name__}: {exc}"]
    return []


# ---------------------------------------------------------------------------- capabilities parsing + gates 4/5

_PORT_STYLES = {"scalar", "bare_map", "items_fields", "items_properties"}


def parse_capabilities(raw: str) -> tuple[dict | None, list[str]]:
    """Parse the model's capabilities.json text. Returns (obj, problems)."""
    raw = raw.strip()
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[1].rsplit("```", 1)[0].strip()
    try:
        obj = json.loads(raw)
    except Exception as exc:  # noqa: BLE001
        return None, [f"capabilities: not valid JSON: {exc}"]
    if not isinstance(obj, dict):
        return None, ["capabilities: top level is not an object"]
    for key in ("provides", "requires", "peer_injection"):
        obj.setdefault(key, [])
        if not isinstance(obj[key], list):
            return None, [f"capabilities: {key} must be a list"]
    obj.setdefault("confidence", "high")
    return obj, []


def _schema_field_refs(caps: dict) -> list[tuple[str, str]]:
    """(where, field_name) for every capabilities value that names a schema field — gate 4 checks each
    exists. Backend/capability tokens are NOT field names and are skipped here (gate 5 handles them)."""
    refs: list[tuple[str, str]] = []
    for p in caps.get("provides", []):
        if isinstance(p, dict):
            if p.get("port_field"):
                refs.append(("provides.port_field", p["port_field"]))
            for role, field in (p.get("provisionable") or {}).items():
                if field:
                    refs.append((f"provides.provisionable.{role}", field))
    for r in caps.get("requires", []):
        if isinstance(r, dict):
            if r.get("backend_field"):
                refs.append(("requires.backend_field", r["backend_field"]))
            for role, field in (r.get("fields") or {}).items():
                if field:
                    refs.append((f"requires.fields.{role}", field))
    for pi in caps.get("peer_injection", []):
        if isinstance(pi, dict) and pi.get("field"):
            refs.append(("peer_injection.field", pi["field"]))
    return refs


def gate_fields(caps: dict, schema: dict) -> list[str]:
    keys = set(schema or {})
    problems = []
    for where, field in _schema_field_refs(caps):
        if field not in keys:
            problems.append(f"fields: {where}='{field}' is not a schema field")
    # peer_injection.items_style must be one of the four known conventions.
    for pi in caps.get("peer_injection", []):
        style = isinstance(pi, dict) and pi.get("items_style")
        if style and style not in _PORT_STYLES:
            problems.append(f"fields: peer_injection.items_style '{style}' unknown (use {sorted(_PORT_STYLES)})")
    return problems


def gate_vocab(caps: dict) -> list[str]:
    """Every capability/backend token must be canonical — UNLESS the artifact is flagged review."""
    if caps.get("confidence") == "review":
        return []  # a human will canonicalise; don't block
    cap_backends, _ = _vocab_index()
    problems = []

    def _check(cap: str, backends: list[str], where: str) -> None:
        if cap not in cap_backends:
            problems.append(f"vocab: {where} capability '{cap}' not in vocabulary")
            return
        for b in backends:
            if b and b not in cap_backends[cap]:
                problems.append(f"vocab: {where} backend '{b}' not valid for capability '{cap}'")

    for p in caps.get("provides", []):
        if isinstance(p, dict):
            _check(p.get("capability", ""), [p.get("backend", "")] if p.get("backend") else [], "provides")
    for r in caps.get("requires", []):
        if isinstance(r, dict):
            _check(r.get("capability", ""), r.get("backends", []) or [], "requires")
    for pi in caps.get("peer_injection", []):
        if isinstance(pi, dict) and pi.get("capability"):
            if pi["capability"] not in cap_backends:
                problems.append(f"vocab: peer_injection capability '{pi['capability']}' not in vocabulary")
    return problems


# ---------------------------------------------------------------------------- combined


# ---------------------------------------------------------------------------- prompts (shared)

SYSTEM_TEMPLATE = """You enrich a Linux service's Jinja2 config template so it is SELF-DOCUMENTING and safe
to reuse in an Ansible role. Self-documentation is a hard, global principle: the result must be commented,
documented and self-explanatory — someone must understand the whole configuration by reading the template
alone.

You are producing an ANSIBLE Jinja2 template (Ansible's engine is standard Jinja2). Follow the format
EXACTLY. Precision here is the whole job.

== JINJA2 SYNTAX (obey precisely) ==
- Three delimiters, nothing else: `{{ expression }}` prints a value; `{% statement %}` is control flow;
  `{# comment #}` is a Jinja comment removed from output.
- EVERY block statement MUST be closed with its matching end tag, correctly nested:
  `{% for x in xs %}…{% endfor %}`, `{% if c %}…{% elif d %}…{% else %}…{% endif %}`, `{% set … %}`,
  `{% macro … %}{% endmacro %}`. An unmatched or misspelled end tag (writing `endfor` where the block was
  `{% if %}`) is a fatal error. Never leave a block open.
- To emit LITERAL braces that are part of the target config (PHP `${...}`, C `{ }`, `${VAR}`), do NOT wrap
  them in Jinja. Only `{{` and `{%` are special to Jinja; a bare `{` or `}` is literal text, written as-is.
  If a literal `{{` or `{%` must appear, use `{% raw %}…{% endraw %}`. NEVER write `{{ '{' }}` noise.
- Filters chain with `|` and take args in parentheses: `{{ xs | join(', ') }}`.

== ALLOWED FILTERS — use ONLY these; NEVER invent one ==
- Jinja2 built-ins: default(d) [alias d], length/count, join, upper, lower, capitalize, title, trim,
  replace, indent, int, float, round, abs, min, max, sum, first, last, list, sort, unique, reverse, select,
  reject, selectattr, rejectattr, map, dictsort, groupby, string, tojson, format, escape/e, urlencode,
  truncate, wordwrap, batch, slice, attr, items.
- Ansible filters (also allowed): default(omit), mandatory, ternary, bool, to_json, to_nice_json, from_json,
  to_yaml, to_nice_yaml, from_yaml, combine, dict2items, items2dict, zip, product, regex_replace,
  regex_search, regex_findall, b64encode, b64decode, quote, comment, hash, password_hash, ipaddr.
- FORBIDDEN: any filter not in these lists. NEVER use `json_encode` (that is PHP — use `tojson`), and never
  a made-up name. If you need JSON, use `tojson`.

== NO ARBITRARY PYTHON ==
- Jinja is NOT Python. No `isinstance`, `break`, `continue`, lambdas, or Python builtins. Use Jinja TESTS:
  `{% if x is defined %}`, `is string`, `is number`, `is iterable`, `is mapping`, `is boolean`. Assume a
  variable is the type its schema default implies; do not type-check defensively.
- To iterate a MAPPING (a `type: object` field), NEVER call `.items()`/`.keys()`/`.values()` — those are
  Python methods and fail at render. Use `{% for k, v in mymap | dict2items %}` (or `| dictsort`). To
  iterate a LIST of objects, `{% for item in mylist %}` then `{{ item.field }}`.

== ENRICHMENT RULES (all mandatory) ==
1. NEVER break the template. It must parse and render as valid Ansible Jinja2. Preserve the rendered
   config's structure and the EXACT directive names/paths the software expects. Use the SAME variable names
   as the schema fields — do not rename, do not invent dotted names like `server.port` for `server_port`.
2. EVERY variable reference gets its default inline: `{{ name | default(D) }}`, D = that field's schema
   default. Quote string defaults ('localhost'), numbers/booleans bare (3306, true), [] or {} for empty
   list/dict. For dotted access, default the PARENT: `{{ (a | default({})).b | default(x) }}` — a bare
   `{{ a.b | default(x) }}` still fails when `a` is unset.
3. Above each directive, put that field's schema DESCRIPTION as a comment in the TARGET FILE's native
   comment syntax: `#` for conf/ini/yaml/toml, `;` where used, `/* … */` or `//` for php/c-like,
   `<!-- … -->` for xml. Concise but complete. This is what makes the template self-explanatory.
4. If the ORIGINAL template is broken (invented filters, unbalanced blocks, literal-brace noise), FIX it
   while enriching — the output must be correct even if the input was not."""

SYSTEM_CAPABILITIES = """You ALSO emit a capabilities.json describing how this package connects to others —
the machine-readable contract a deterministic matcher uses to wire services together like Lego bricks.

A `provides` entry = this package OFFERS a service others connect to. A `requires` entry = this package
NEEDS a service from another. `peer_injection` = wiring writes the peer's address INTO one of this
package's fields (e.g. an NFS server's exports list gets the client IP).

Use ONLY capability and backend tokens from the VOCABULARY given in the user message. If the package's role
is not covered by the vocabulary, emit `"confidence": "review"` and your best guess — never invent a token
silently.

Field names in capabilities.json (port_field, backend_field, fields.*, provisionable.*, peer_injection.field)
MUST be real keys from the schema — never a name that isn't in the schema fields list.

Distinguish PROVIDER vs CONSUMER fields:
- A provider (the database itself) uses UNPREFIXED fields: `port`, `bind_address`, `listen_addresses`.
- A consumer (an app using a database) uses PREFIXED pairs: `db_host`+`db_port`+`db_user`+`db_password`,
  or `mysql_host`+`mysql_port`. Map each vocabulary connection-field ROLE (host/port/name/user/password) to
  the matching schema key; omit a role if the schema has no such field.

Traps: `50-server.cnf`/`my.cnf` are MariaDB/MySQL config WITHOUT an engine word in the name. `mongodb`,
`pgbouncer` may have no port field. `mysqld.cnf:mysql_user` and `memcached.conf:user` are OS run-as
accounts, NOT credentials — do not map them as `user`. If the package is a plain leaf config with no
network service (e.g. hdparm, sysctl), emit empty provides/requires.

capabilities.json shape (emit valid JSON, no comments):
{
  "provides": [{"capability": "database", "backend": "postgresql", "port_field": "port",
                "default_port": 5432, "provisionable": {"databases": "<schema field or omit>",
                "users": "<schema field or omit>"}}],
  "requires": [{"capability": "database", "backends": ["mysql","mariadb"], "backend_field": "<schema field or null>",
                "fields": {"host": "db_host", "port": "db_port", "name": "db_name", "user": "db_user",
                           "password": "db_password"}}],
  "peer_injection": [{"capability": "nfs", "field": "exports", "kind": "client_list",
                      "items_style": "bare_map"}],
  "confidence": "high"
}

== OUTPUT FORMAT (exactly this, no fences, no prose) ==
{T_MARK}
<the enriched template text>
{C_MARK}
<the capabilities.json>
""".replace("{T_MARK}", T_MARK).replace("{C_MARK}", C_MARK)


def vocabulary_brief() -> str:
    """Compact capability→backends listing for the prompt."""
    v = vocabulary()
    lines = []
    for cap, spec in v["capabilities"].items():
        lines.append(f"- {cap}: backends [{', '.join(spec.get('backends', []))}] "
                     f"— roles [{', '.join(spec.get('connection_fields', []))}]")
    return "\n".join(lines)


def fields_brief(props: dict) -> str:
    out = []
    for k, val in props.items():
        if not isinstance(val, dict):
            continue
        out.append(f"- {k}: default={val.get('default')!r}  desc={(val.get('description') or '')[:140]!r}")
    return "\n".join(out)


def build_user(name: str, template: str, props: dict) -> str:
    return (
        f"Package: {name}\n\n=== schema fields (name, default, description) ===\n{fields_brief(props)}\n\n"
        f"=== capability vocabulary (use ONLY these tokens) ===\n{vocabulary_brief()}\n\n"
        f"=== current template.j2 ===\n{template}\n\n"
        f"Return the enriched template and its capabilities.json in the required {T_MARK}/{C_MARK} format."
    )


def build_fix_user(name: str, template: str, caps_raw: str, problems: list[str], props: dict) -> str:
    """The self-correction prompt: feed the EXACT gate errors back with targeted reminders. This exact
    feedback loop is what took the pilot from 3/10 (one-shot) to 10/10."""
    return (
        f"Package: {name}\nYour output FAILED these deterministic gates:\n"
        + "\n".join(f"  - {p}" for p in problems)
        + "\n\nFix EVERY listed problem. Reminders: close every {% %} block with its end tag; give every "
        "variable an inline `| default(D)`; for dotted access default the parent `(a|default({})).b`; do "
        "NOT call .items()/.keys() on a mapping — use `| dict2items`; use ONLY allowed filters (tojson not "
        "json_encode); capabilities field names must be real schema keys; capability/backend tokens must "
        "come from the vocabulary (or set confidence=review).\n\n"
        f"=== schema fields ===\n{fields_brief(props)}\n\n"
        f"=== capability vocabulary ===\n{vocabulary_brief()}\n\n"
        f"=== your template to correct ===\n{template}\n\n"
        f"=== your capabilities.json to correct ===\n{caps_raw}\n\n"
        f"Return the corrected template and capabilities.json in the required {T_MARK}/{C_MARK} format."
    )


def split_artifacts(reply: str) -> tuple[str, str]:
    """Split a model reply into (template_text, capabilities_raw). Tolerant of a missing capabilities
    section (returns '' for it, which parse_capabilities will reject)."""
    reply = reply.strip()
    if T_MARK in reply:
        reply = reply.split(T_MARK, 1)[1]
    if C_MARK in reply:
        tmpl, caps = reply.split(C_MARK, 1)
    else:
        tmpl, caps = reply, ""
    return _strip_fence(tmpl), caps.strip()


def _strip_fence(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1].rsplit("```", 1)[0]
    return text.strip()


def run_all_gates(name: str, template: str, caps_raw: str, schema: dict, sample: dict) -> tuple[dict | None, list[str]]:
    """Run every gate. Returns (parsed_capabilities_or_None, problems). Empty problems == accept."""
    problems: list[str] = []
    problems += gate_contract(template, schema)
    problems += gate_gonja(template, sample)
    problems += gate_ansible_empty(template)
    caps, cap_problems = parse_capabilities(caps_raw)
    problems += cap_problems
    if caps is not None:
        problems += gate_fields(caps, schema)
        problems += gate_vocab(caps)
    return caps, problems
