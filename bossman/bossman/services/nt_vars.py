"""Block G11 (NT format, step 2): variable substitution for NestedText
runbooks/roles.

Per the agreed spec (docs/nt-format.md), any of these bracket styles resolve
the same variable — the author picks whichever they like:

    $var        ${var}        {{ var }}        {{var}}

plus the two useful bash modifiers (text templating only — no command
substitution, no arithmetic; that's logic and belongs in a `starlark` step):

    ${var:-default}   use `default` if var is unset/empty
    ${var:?message}   fail with `message` if var is unset/empty (required)

A string that is *entirely* one placeholder yields the variable's native
value (so `port: ${mysql_port}` can be an int); an embedded placeholder is
stringified. An unresolved bare reference is an error (never a silent empty
string). Substitution walks dicts/lists recursively.

Variable scopes merge GPO-style (weakest→strongest) via merge_scopes — the
same precedence the check-assignment resolver uses (global < group < OU <
host < role param < loop item).
"""

from __future__ import annotations

import re
from typing import Any


class NTVarError(Exception):
    """An unresolved / required-but-missing variable reference."""


# One token in any supported style. Ordered so ${...} is tried before a bare
# $name (else "${x}" would match "$" + stray). Groups:
#   j        -> {{ name }}
#   b/op/arg -> ${name}, ${name:-arg}, ${name:?arg}
#   s        -> $name
_TOKEN = re.compile(
    r"\{\{\s*(?P<j>\w+)\s*\}\}"
    r"|\$\{(?P<b>\w+)(?:(?P<op>:-|:\?)(?P<arg>[^}]*))?\}"
    r"|\$(?P<s>\w+)"
)


def _is_empty(v: Any) -> bool:
    return v is None or v == ""


def _resolve_one(name: str, op: str | None, arg: str | None, vars: dict[str, Any]) -> Any:
    present = name in vars and not _is_empty(vars[name])
    if op == ":-":
        return vars[name] if present else (arg if arg is not None else "")
    if op == ":?":
        if not present:
            raise NTVarError(arg or f"required variable {name!r} is unset")
        return vars[name]
    # no modifier: must be present
    if name not in vars:
        raise NTVarError(f"unresolved variable reference to {name!r}")
    return vars[name]


def substitute_str(s: str, vars: dict[str, Any]) -> Any:
    """Substitute one string. If it is exactly one placeholder, return the
    variable's native type; otherwise return the interpolated string."""
    whole = _TOKEN.fullmatch(s.strip())
    if whole:
        name = whole.group("j") or whole.group("b") or whole.group("s")
        return _resolve_one(name, whole.group("op"), whole.group("arg"), vars)

    def _repl(m: re.Match) -> str:
        name = m.group("j") or m.group("b") or m.group("s")
        return str(_resolve_one(name, m.group("op"), m.group("arg"), vars))

    return _TOKEN.sub(_repl, s)


def substitute(val: Any, vars: dict[str, Any]) -> Any:
    """Recursively substitute in a value (str / dict / list); other scalars
    pass through unchanged."""
    if isinstance(val, str):
        return substitute_str(val, vars)
    if isinstance(val, dict):
        return {k: substitute(v, vars) for k, v in val.items()}
    if isinstance(val, list):
        return [substitute(v, vars) for v in val]
    return val


def merge_scopes(*scopes: dict[str, Any] | None) -> dict[str, Any]:
    """Merge variable scopes weakest→strongest (later wins), skipping None.
    Callers pass them in GPO order: global, group_vars, ou_vars(root→leaf),
    host_vars, role parameters, loop item."""
    out: dict[str, Any] = {}
    for scope in scopes:
        if scope:
            out.update(scope)
    return out
