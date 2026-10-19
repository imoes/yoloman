"""A template made from the file a package SHIPS — mechanically, the same way on every family.

    .venv-host/bin/python -m bossman.tools.template_from_shipped <shipped-file> <template-dir> [--target PATH]
                                                                 [--family redhat] [--required key,…]

Why: the role templates the model wrote for daemons like opendmarc and squid activated settings the shipped file only
documents, and the wizard renders ONE role's parameters on every family — so a family template with other field
names silently drops the operator's values. Here every directive becomes a field named after the DIRECTIVE
(`SyslogFacility` → `syslog_facility`, `http_port` → `http_port`), so the Debian and the EL template of a role agree
on their fields without anyone mapping them.

What counts as a directive (prose must stay prose — "# The …" is not a setting called `The`):
  1. the file's own documentation headers: squid's `#  TAG: http_port`, opendkim/opendmarc's `##  AuthservID (string)`;
  2. every ACTIVE `key value` / `key = value` line;
  3. a commented `#Key value` with no space after the comment character.
A directive the file sets or shows exactly once becomes a field: an active line keeps its shipped value as the default
(`Key {{ key | default('value') }}`); a commented example renders the shipped line verbatim until the field is set. A
directive that appears more than once (squid's `acl`, `http_access`) stays as the file has it.

The defaults render the shipped file byte for byte — checked by the caller with render-check — so applying the role with
nothing set changes nothing.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path

from bossman.tools.activate_commented_settings import present

#: `#  TAG: http_port` (squid) and `##  AuthservID (string)` / `##  PidFile path` (opendkim, opendmarc). A header names a
#: directive only if the file also has a setting line for it — `##  Sets the …` is prose, and nothing reads `# Sets …`.
DOC_HEADERS = (re.compile(r"^#\s+TAG:\s+([A-Za-z_][\w.-]*)"), re.compile(r"^##\s+([A-Z][A-Za-z0-9_]+)(?:\s|$)"))
#: indent, comment (optional), key, separator, value.
SETTING = re.compile(r"^(?P<indent>\s*)(?P<hash>#\s?)?(?P<key>[A-Za-z_][\w.-]*)(?P<sep>\s*=\s*|[ \t]+)(?P<value>\S.*)$")


#: Names the template engine reserves — a field called `in` or `include` broke the whole template ("If-condition is
#: malformed", collectd's `In`/`Include` directives).
_RESERVED = {"in", "is", "not", "and", "or", "if", "else", "elif", "endif", "for", "endfor", "include", "import",
             "from", "true", "false", "none", "block", "extends", "macro", "call", "filter", "set", "with", "without",
             "context", "raw", "loop", "super", "self", "varargs", "kwargs", "caller", "namespace", "endblock",
             "endmacro", "endcall", "endfilter", "endset", "endwith", "endraw", "recursive", "scoped", "ignore",
             "missing", "pluralize", "trans", "endtrans", "break", "continue"}


def field_name(key: str) -> str:
    """The field for a directive: snake_case, and never a name the engine reserves."""
    name = snake(key)
    return name + "_directive" if name in _RESERVED or name[:1].isdigit() else name


def snake(key: str) -> str:
    """`SyslogFacility` → `syslog_facility`, `AuthservID` → `authserv_id`, `TrustedAuthservIDs` → `trusted_authserv_ids`,
    `UMask` → `umask`, `HTTPPort` → `http_port`, `http_port` stays."""
    s = re.sub(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z]{2})(?=[A-Z][a-z]{2,})", "_", key)
    return re.sub(r"[^a-z0-9_]", "_", s.lower())


def directives_of(text: str) -> set[str]:
    headers, settings, found = set(), set(), set()
    for line in text.split("\n"):
        for rx in DOC_HEADERS:
            m = rx.match(line)
            if m:
                headers.add(m.group(1))
        m = SETTING.match(line)
        if m:
            settings.add(m["key"])
            if not m["hash"] or m["hash"] == "#":
                found.add(m["key"])
    return found | (headers & settings)


def sample_of(shipped: str, schema: dict) -> dict:
    """A sample that exercises every field: the value each directive has in the file — the shipped value of an active
    line, the example value of a commented one (so a render with the sample turns the documented examples on)."""
    out = {}
    for line in shipped.split("\n"):
        m = SETTING.match(line)
        if m and field_name(m["key"]) in schema and field_name(m["key"]) not in out:
            out[field_name(m["key"])] = m["value"].rstrip()
    return dict(sorted(out.items()))


#: `directive = {{ field … }}` / `#directive value {{ field }}` in a role template — which field the role uses for a directive.
_ROLE_LINE = re.compile(r"^\s*[#;]?\s*(?P<key>[A-Za-z_][\w.-]*)(?:\s*=\s*|[ \t]+)[^\n{]*\{\{-?\s*(?P<var>[A-Za-z_]\w*)")


def role_names(role_template: str) -> dict[str, str]:
    """{directive: field} as a role's template writes it — `myhostname = {{ hostname }}` → myhostname: hostname.
    A directive written with two different fields is ambiguous and left out."""
    seen: dict[str, set[str]] = {}
    depth = 0
    for line in role_template.split("\n"):
        # the live branch of a repaired line: `{% if <present(v)> %}key = {{ v }}{% else %}#key …{% endif %}`
        live = re.sub(r"^\s*\{%-?\s*if\b.*?%\}", "", line).split("{% else", 1)[0]
        m = _ROLE_LINE.match(live) if depth == 0 else None
        if m:
            seen.setdefault(m["key"], set()).add(m["var"])
        depth = max(0, depth + len(re.findall(r"\{%-?\s*for\b", line)) - len(re.findall(r"\{%-?\s*endfor\b", line)))
    return {k: next(iter(v)) for k, v in seen.items() if len(v) == 1}


def lit(text: str) -> str:
    """A shipped line as template TEXT: the file's own `{{`, `{%`, `{#` become literals, or the engine reads them as
    tags — php-fpm's access-log format `%{%Y-%m-%dT%H:%M:%S%z}t` failed to parse ("ControlStructure 'Y' not found")."""
    return re.sub(r"\{([{%#])", lambda m: "{{ '{" + m.group(1) + "' }}", text)


def build(shipped: str, required: set[str] = frozenset(), names: dict[str, str] | None = None,
          role_schema: dict | None = None) -> tuple[str, dict]:
    """(template body, schema) for the shipped text. `names` maps a directive to the ROLE's field for it, so a family
    template built here shares the role's field names (G5); `role_schema` lends those fields their type, value set and
    description — the default stays this file's own value."""
    names, role_schema = names or {}, role_schema or {}
    known = directives_of(shipped)
    lines = shipped.split("\n")
    matches = [SETTING.match(ln) for ln in lines]
    counts = Counter(m["key"] for m in matches if m and m["key"] in known)
    # A directive the file sets ACTIVE exactly once is that setting, however many commented examples document it
    # (postfix's main.cf: `#inet_interfaces = all`, `#inet_interfaces = $myhostname`, `inet_interfaces = localhost`).
    # Its active line becomes the field; the examples stay documentation.
    active = Counter(m["key"] for m in matches if m and m["key"] in known and not m["hash"])
    fielded_once: set[str] = set()
    out, schema = [], {}
    for line, m in zip(lines, matches):
        # …and a directive the ROLE names that the file only shows as several commented examples is anchored at the
        # first example (live when set, the example verbatim when not) — the role asks for it, so the EL file offers it.
        # A value that continues on the next line (`… +smtp_syntax_error \`) is not one line's value: in a default
        # literal its backslash escaped the closing quote and exim's template did not parse.
        if m and m["value"].rstrip().endswith("\\"):
            out.append(lit(line))
            continue
        single = m and m["key"] in known and (counts[m["key"]] == 1 or (active[m["key"]] == 1 and not m["hash"])
                                              or (active[m["key"]] == 0 and m["key"] in names
                                                  and (m["hash"] == "#" or "=" in m["sep"])))   # an example, not prose
        if not single or m["key"] in fielded_once:
            out.append(lit(line))
            continue
        fielded_once.add(m["key"])
        key, value = m["key"], m["value"].rstrip()
        var = names.get(key) or field_name(key)
        if var in schema:          # two directives mapped to one field: keep the second as the file has it
            out.append(lit(line))
            continue
        spec: dict = {"type": "string", "description": f"{key} (as documented in the shipped file)."}
        lent = role_schema.get(var) if var in role_schema else None
        if isinstance(lent, dict):
            for k in ("type", "description", "enum", "enum_labels", "enum_open", "min", "max"):
                if k in lent:
                    spec[k] = lent[k]
            if spec.get("type") not in ("string", "number", "bool"):
                spec["type"] = "string"     # the role's list/object shape does not fit one directive line
        # A path-like directive takes `no` as "none", not as a switch: postfix's `html_directory = no` became a yes/no
        # dropdown, and `yes` is refused ("should be "no" or an absolute path name", measured in the pod e2e).
        path_like = re.search(r"(?:^|_)(?:dir|directory|path|file|socket|prefix)$", snake(key))   # not use_sendfile
        if "enum" not in spec and not path_like and value.lower() in ("yes", "no", "true", "false", "on", "off"):
            pair = {"yes": ["yes", "no"], "no": ["yes", "no"], "true": ["true", "false"], "false": ["true", "false"],
                    "on": ["on", "off"], "off": ["on", "off"]}[value.lower()]
            spec["enum"] = [p if value.islower() else p.capitalize() for p in pair]
        if m["hash"]:
            spec["default"] = None
            spec["description"] += f" Unset keeps the shipped commented line ({line.strip()})."
            out.append("{%% if %s %%}%s%s%s{{ %s }}\n{%% else %%}%s\n{%% endif %%}"
                       % (present(var), m["indent"], key, m["sep"], var, lit(line)))
        else:
            spec["default"] = value
            if spec.get("type") == "number" and re.fullmatch(r"-?\d+(\.\d+)?", value):
                spec["default"] = float(value) if "." in value else int(value)
            elif spec.get("type") == "bool":
                spec["type"] = "string"     # the file's word (yes/no) is the value; a JSON bool would render True
            if "enum" in spec and spec["default"] not in spec["enum"]:
                spec.pop("enum", None)      # the role's set does not hold this file's value: no false dropdown
                spec.pop("enum_labels", None)
                spec.pop("enum_open", None)  # "open set" without a set is a contradiction (check_catalog_fit)
            out.append("%s%s%s{{ %s | default('%s') }}" % (m["indent"], key, m["sep"], var, value.replace("'", "\\'")))
        if key in required or var in required:
            spec["required"] = True
        schema[var] = spec
    body = ""
    for i, ln in enumerate(out):   # the newline lives inside both branches; none after {% endif %}
        body += ln if ln.endswith("{% endif %}") else ln + ("\n" if i < len(out) - 1 else "")
    return body, dict(sorted(schema.items()))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("shipped")
    ap.add_argument("template_dir")
    ap.add_argument("--target", required=True, help="the path the file has on the host (meta target_path)")
    ap.add_argument("--family", default="", help="redhat for an EL family template")
    ap.add_argument("--required", default="", help="comma-separated directives the role must ask for")
    ap.add_argument("--names-from", default="", help="the ROLE's template dir: its field names (and types, value "
                                                      "sets, descriptions) are used for the directives it writes")
    args = ap.parse_args()
    names, role_schema = {}, {}
    if args.names_from:
        rd = Path(args.names_from)
        role_schema = json.loads((rd / "schema.json").read_text()) if (rd / "schema.json").is_file() else {}
        names = {k: v for k, v in role_names((rd / "template.j2").read_text(errors="replace")).items()
                 if v in role_schema}      # a loop item or an undeclared name is not a role field
    body, schema = build(Path(args.shipped).read_text(errors="replace"),
                         {s.strip() for s in args.required.split(",") if s.strip()}, names, role_schema)
    out = Path(args.template_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "template.j2").write_text(body)
    (out / "schema.json").write_text(json.dumps(schema, indent=2) + "\n")
    (out / "sample.json").write_text(json.dumps(sample_of(Path(args.shipped).read_text(errors="replace"), schema),
                                                indent=2) + "\n")
    meta = {"target_path": args.target, "source": "hand", "witness": "shipped-file (template_from_shipped)"}
    if args.family:
        meta["family"] = args.family
    (out / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    if not (out / "capabilities.json").exists():
        (out / "capabilities.json").write_text(json.dumps(
            {"provides": [], "requires": [], "peer_injection": [], "confidence": "review"}, indent=2) + "\n")
    print(f"{out.name}: {len(schema)} field(s) from {args.shipped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
