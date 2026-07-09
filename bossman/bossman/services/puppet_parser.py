"""Deterministic Puppet manifest (.pp) → canonical plan parser
(docs/zielbestimmung.md roadmap: Puppet last, Turing-complete). Parses the
declarative resource-declaration subset:

    package { 'nginx':
      ensure => installed,
    }
    service { 'nginx':
      ensure => running,
      enable => true,
      require => Package['nginx'],
    }

Each resource becomes one canonical plan step (prefix "puppet"). Bounded and
honest: classes/defines/nodes, conditionals (if/unless/case), chaining
(->/~>), variables (`$x`) and interpolation (`${…}`), and unknown resource
types all raise PlanError — and any manifest text that is NOT a recognized
resource declaration is reported rather than silently ignored.
"""

from __future__ import annotations

import re
from typing import Any, Callable

from bossman.services.plan_loader import PlanError

# Constructs beyond a flat list of resource declarations — refused up front.
_FORBIDDEN = re.compile(
    r"(\bclass\b)|(\bdefine\b)|(\bnode\b)|(\bif\b)|(\bunless\b)|(\bcase\b)"
    r"|(\binclude\b)|(->)|(~>)|(\$\{)|(\$\w)"
)
# One resource declaration: `type { 'title': <body> }` (body up to the first
# `}`; the subset has no nested braces).
_RESOURCE = re.compile(r"(\w+)\s*\{\s*(['\"])(.+?)\2\s*:(.*?)\}", re.DOTALL)
_STRING = re.compile(r"""^(['"])(.*)\1$""")
_INT = re.compile(r"^-?\d+$")
_RESOURCE_REF = re.compile(r"^[A-Z]\w*\[.+\]$")  # e.g. Package['nginx'] — a requisite target

# Puppet metaparameters / requisites — dropped (ordering is step sequence).
_METAPARAMS = frozenset(
    {"require", "before", "notify", "subscribe", "tag", "stage", "alias", "schedule", "audit", "loglevel", "noop"}
)


def _strip_comments(text: str) -> str:
    out: list[str] = []
    for raw in text.splitlines():
        line, in_str = [], None
        for c in raw:
            if in_str is not None:
                line.append(c)
                if c == in_str:
                    in_str = None
            elif c in ("'", '"'):
                in_str = c
                line.append(c)
            elif c == "#":
                break
            else:
                line.append(c)
        out.append("".join(line))
    return "\n".join(out)


def _split_top_commas(s: str) -> list[str]:
    parts, depth, cur = [], 0, []
    for c in s:
        if c in "[":
            depth += 1
        elif c in "]":
            depth -= 1
        if c == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    if "".join(cur).strip():
        parts.append("".join(cur))
    return [p.strip() for p in parts if p.strip()]


def _value(tok: str) -> Any:
    tok = tok.strip()
    m = _STRING.match(tok)
    if m:
        return m.group(2)
    if tok in ("true", "false"):
        return tok == "true"
    if _INT.match(tok):
        return int(tok)
    if tok.startswith("[") and tok.endswith("]"):
        inner = tok[1:-1].strip()
        return [_value(t) for t in _split_top_commas(inner)] if inner else []
    if _RESOURCE_REF.match(tok):
        return tok  # only ever seen on metaparams, which are dropped
    if re.match(r"^\w+$", tok):
        return tok  # bareword (ensure => installed, running, directory, …)
    raise PlanError(f"puppet: cannot parse value {tok!r}")


# --- resource → (module, body) mappers ----------------------------------

_PKG_ENSURE = {"installed": "present", "present": "present", "latest": "latest", "absent": "absent", "purged": "absent"}


def _package(title: str, a: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    ensure = a.get("ensure", "installed")
    return "package", {"name": a.get("name", title), "state": _PKG_ENSURE.get(str(ensure), "present")}


def _service(title: str, a: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    body: dict[str, Any] = {"name": a.get("name", title)}
    ensure = a.get("ensure")
    if ensure in ("running", "true"):
        body["state"] = "started"
    elif ensure in ("stopped", "false"):
        body["state"] = "stopped"
    if "enable" in a:
        body["enabled"] = a["enable"] if isinstance(a["enable"], bool) else str(a["enable"]) == "true"
    if "state" not in body and "enabled" not in body:
        body["state"] = "started"
    return "service", body


def _file(title: str, a: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    path = a.get("path", title)
    ensure = a.get("ensure", "file")
    if ensure in ("absent",):
        return "file", {"path": path, "state": "absent"}
    if ensure in ("directory",):
        body: dict[str, Any] = {"path": path, "state": "directory"}
        for k in ("mode", "owner", "group"):
            if k in a:
                body[k] = a[k]
        return "file", body
    if ensure in ("link",):
        return "file", {"path": path, "src": a["target"], "state": "link"}
    body = {"dest": path}
    for k, ans in (("content", "content"), ("source", "src"), ("mode", "mode"), ("owner", "owner"), ("group", "group")):
        if k in a:
            body[ans] = a[k]
    return "copy", body


def _exec(title: str, a: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    return "command", {"cmd": a.get("command", title)}


def _user(title: str, a: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    body: dict[str, Any] = {"name": a.get("name", title)}
    body["state"] = "absent" if a.get("ensure") == "absent" else "present"
    for k, ans in (("uid", "uid"), ("gid", "group"), ("home", "home"), ("shell", "shell")):
        if k in a:
            body[ans] = a[k]
    return "user", body


def _group(title: str, a: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    body: dict[str, Any] = {"name": a.get("name", title)}
    body["state"] = "absent" if a.get("ensure") == "absent" else "present"
    if "gid" in a:
        body["gid"] = a["gid"]
    return "group", body


_MAPPING: dict[str, Callable[[str, dict[str, Any]], tuple[str, dict[str, Any]]]] = {
    "package": _package,
    "service": _service,
    "file": _file,
    "exec": _exec,
    "user": _user,
    "group": _group,
}


def parse_puppet_manifest(source_text: str, name: str) -> dict[str, Any]:
    """Parse a Puppet manifest into the canonical plan raw dict (plan `name`
    supplied, since a manifest carries none)."""
    text = _strip_comments(source_text)
    if _FORBIDDEN.search(text):
        raise PlanError(
            "puppet: only flat resource declarations are supported — classes/defines/nodes, "
            "conditionals, chaining (->/~>), variables and interpolation are out of scope"
        )

    steps: list[dict[str, Any]] = []
    # Verify nothing but recognized resources is present (no silent skips):
    # blanking each match must leave only whitespace/semicolons behind.
    leftover = _RESOURCE.sub("", text).replace(";", "").strip()
    if leftover:
        raise PlanError(f"puppet: unparsed manifest content: {leftover.splitlines()[0]!r}")

    for m in _RESOURCE.finditer(text):
        rtype, title, body_src = m.group(1), m.group(3), m.group(4)
        attrs: dict[str, Any] = {}
        for pair in _split_top_commas(body_src):
            if "=>" not in pair:
                raise PlanError(f"puppet: resource {rtype}[{title}]: cannot parse attribute {pair!r}")
            key, _, val = pair.partition("=>")
            key = key.strip()
            if key in _METAPARAMS:
                continue
            attrs[key] = _value(val)

        mapper = _MAPPING.get(rtype)
        if mapper is None:
            raise PlanError(
                f"puppet: resource type {rtype!r} is not mapped yet — supported: {', '.join(sorted(_MAPPING))}"
            )
        module, mbody = mapper(title, attrs)
        steps.append({"name": f"{rtype}[{title}]", f"ansible.builtin.{module}": mbody})

    if not steps:
        raise PlanError("puppet: no resources found")
    return {"name": name, "description": f"Imported from Puppet manifest ({name}).", "steps": steps}
