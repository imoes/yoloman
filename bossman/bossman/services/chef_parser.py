"""Deterministic Chef recipe → canonical plan parser (docs/zielbestimmung.md
roadmap: Chef after Salt). Unlike Salt's YAML, a Chef recipe is a Ruby DSL, so
this is a real (line-oriented) parser for the DECLARATIVE resource subset:

    <resource_type> '<name>' do
      <attribute> <value>
      action :<sym>            # or  action [:<sym>, :<sym>]
    end

plus the one-line form `<resource_type> '<name>'` (default action). Each
resource becomes one canonical plan step, stored under prefix "chef".

Bounded and honest: Ruby control flow, string interpolation (`#{…}`), block
parameters (`do |x|`), and unknown resource types all raise PlanError naming
what was unsupported — nothing is silently mis-parsed or dropped. Chef is
Turing-complete; this covers the common configuration-management resources,
not the whole language.
"""

from __future__ import annotations

import re
from typing import Any, Callable

from bossman.services.plan_loader import PlanError

_STRING = re.compile(r"""^(['"])(.*)\1$""")
_SYMBOL = re.compile(r"^:(\w+)$")
_INT = re.compile(r"^-?\d+$")
# `type 'name' do` (block) or `type 'name'` (one-liner). Name is a quoted string.
_HEADER = re.compile(r"""^(\w+)\s+(['"])(.+?)\2\s*(do)?\s*$""")
_ATTR = re.compile(r"^(\w+)\s+(.+)$")
# Ruby constructs we deliberately refuse rather than guess at. (String
# interpolation `#{…}` is caught in _value, with a clearer message.)
_UNSUPPORTED = re.compile(r"(\bdo\s*\|)|(^(if|unless|case|while)\b)|(\.each\b)|(\bruby_block\b)")


def _strip_comment(line: str) -> str:
    """Remove a Ruby line comment, but never treat `#` inside a string or the
    `#{` of an interpolation as a comment (so interpolation survives to be
    rejected explicitly in _value)."""
    out: list[str] = []
    in_str: str | None = None
    i = 0
    while i < len(line):
        c = line[i]
        if in_str is not None:
            out.append(c)
            if c == in_str:
                in_str = None
        elif c in ("'", '"'):
            in_str = c
            out.append(c)
        elif c == "#":
            if i + 1 < len(line) and line[i + 1] == "{":
                out.append(c)  # part of '#{' — keep, not a comment
            else:
                break  # rest of the line is a comment
        else:
            out.append(c)
        i += 1
    return "".join(out).strip()


def _split_top_commas(s: str) -> list[str]:
    return [part for part in (p.strip() for p in s.split(",")) if part]


def _value(tok: str) -> Any:
    tok = tok.strip()
    if "#{" in tok:
        raise PlanError(f"chef: ruby string interpolation not supported: {tok!r}")
    m = _STRING.match(tok)
    if m:
        return m.group(2)
    if tok in ("true", "false"):
        return tok == "true"
    if _INT.match(tok):
        return int(tok)
    m = _SYMBOL.match(tok)
    if m:
        return m.group(1)  # a symbol becomes its bare name
    if tok.startswith("[") and tok.endswith("]"):
        inner = tok[1:-1].strip()
        return [_value(t) for t in _split_top_commas(inner)] if inner else []
    raise PlanError(f"chef: cannot parse value {tok!r}")


# --- resource → (module, body) mappers ----------------------------------


def _actions(attrs: dict[str, Any]) -> list[str]:
    a = attrs.get("action")
    if a is None:
        return []
    return [a] if isinstance(a, str) else [str(x) for x in a]


def _package(name: str, attrs: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    acts = _actions(attrs) or ["install"]
    state = {"install": "present", "upgrade": "latest", "remove": "absent", "purge": "absent"}
    chosen = next((state[a] for a in acts if a in state), "present")
    body = {"name": attrs.get("package_name", name), "state": chosen}
    return "package", body


def _service(name: str, attrs: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    acts = _actions(attrs)
    body: dict[str, Any] = {"name": attrs.get("service_name", name)}
    if "stop" in acts:
        body["state"] = "stopped"
    elif "restart" in acts:
        body["state"] = "restarted"
    elif "start" in acts:
        body["state"] = "started"
    if "enable" in acts:
        body["enabled"] = True
    elif "disable" in acts:
        body["enabled"] = False
    if "state" not in body and "enabled" not in body:
        body["state"] = "started"  # bare `service 'x'` → ensure running
    return "service", body


def _file(name: str, attrs: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    if "delete" in _actions(attrs):
        return "file", {"path": attrs.get("path", name), "state": "absent"}
    body: dict[str, Any] = {"dest": attrs.get("path", name)}
    for k, ans in (("content", "content"), ("mode", "mode"), ("owner", "owner"), ("group", "group")):
        if k in attrs:
            body[ans] = attrs[k]
    return "copy", body


def _directory(name: str, attrs: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    if "delete" in _actions(attrs):
        return "file", {"path": attrs.get("path", name), "state": "absent"}
    body: dict[str, Any] = {"path": attrs.get("path", name), "state": "directory"}
    for k, ans in (("mode", "mode"), ("owner", "owner"), ("group", "group")):
        if k in attrs:
            body[ans] = attrs[k]
    return "file", body


def _template(name: str, attrs: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    body: dict[str, Any] = {"dest": attrs.get("path", name)}
    if "source" in attrs:
        body["src"] = attrs["source"]
    for k, ans in (("mode", "mode"), ("owner", "owner"), ("group", "group")):
        if k in attrs:
            body[ans] = attrs[k]
    return "template", body


def _execute(name: str, attrs: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    return "command", {"cmd": attrs.get("command", name)}


def _link(name: str, attrs: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    return "file", {"path": name, "src": attrs["to"], "state": "link"}


def _user(name: str, attrs: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    body: dict[str, Any] = {"name": attrs.get("username", name)}
    body["state"] = "absent" if "remove" in _actions(attrs) else "present"
    for k, ans in (("uid", "uid"), ("gid", "group"), ("home", "home"), ("shell", "shell")):
        if k in attrs:
            body[ans] = attrs[k]
    return "user", body


def _group(name: str, attrs: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    body: dict[str, Any] = {"name": attrs.get("group_name", name)}
    body["state"] = "absent" if "remove" in _actions(attrs) else "present"
    if "gid" in attrs:
        body["gid"] = attrs["gid"]
    return "group", body


def _remote_file(name: str, attrs: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    return "get_url", {"url": attrs["source"], "dest": attrs.get("path", name)}


_MAPPING: dict[str, Callable[[str, dict[str, Any]], tuple[str, dict[str, Any]]]] = {
    "package": _package,
    "apt_package": _package,
    "yum_package": _package,
    "service": _service,
    "file": _file,
    "cookbook_file": _file,
    "directory": _directory,
    "template": _template,
    "execute": _execute,
    "link": _link,
    "user": _user,
    "group": _group,
    "remote_file": _remote_file,
}


def parse_chef_recipe(source_text: str, name: str) -> dict[str, Any]:
    """Parse a Chef recipe into the canonical plan raw dict (with plan `name`,
    since a recipe carries none)."""
    steps: list[dict[str, Any]] = []
    cur_type: str | None = None
    cur_name: str = ""
    cur_attrs: dict[str, Any] = {}

    def emit() -> None:
        nonlocal cur_type
        mapper = _MAPPING.get(cur_type or "")
        if mapper is None:
            raise PlanError(
                f"chef: resource type {cur_type!r} is not mapped yet — supported: {', '.join(sorted(_MAPPING))}"
            )
        module, body = mapper(cur_name, cur_attrs)
        steps.append({"name": f"{cur_type}[{cur_name}]", f"ansible.builtin.{module}": body})
        cur_type = None

    for lineno, raw_line in enumerate(source_text.splitlines(), start=1):
        line = _strip_comment(raw_line)
        if not line:
            continue
        if _UNSUPPORTED.search(line):
            raise PlanError(f"chef: unsupported Ruby construct on line {lineno}: {raw_line.strip()!r}")

        if cur_type is None:
            m = _HEADER.match(line)
            if not m:
                raise PlanError(f"chef: cannot parse line {lineno}: {raw_line.strip()!r}")
            cur_type, cur_name, cur_attrs = m.group(1), m.group(3), {}
            if not m.group(4):  # one-liner, no `do` — emit immediately
                emit()
            continue

        if line == "end":
            emit()
            continue

        m = _ATTR.match(line)
        if not m:
            raise PlanError(f"chef: cannot parse attribute on line {lineno}: {raw_line.strip()!r}")
        cur_attrs[m.group(1)] = _value(m.group(2))

    if cur_type is not None:
        raise PlanError(f"chef: unterminated resource {cur_type!r} (missing 'end')")
    if not steps:
        raise PlanError("chef: no resources found")
    return {"name": name, "description": f"Imported from Chef recipe ({name}).", "steps": steps}
