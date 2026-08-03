"""Variable substitution: real Jinja2 in a SANDBOX — Ansible semantics.

    {{ var }}   {{ var | filter }}   {{ a if b else c }}   ← the only templating syntax

A `$var` / `${var}` / `${var:-default}` / `${var:?msg}` shim used to be rewritten to Jinja here. It is gone,
for two reasons: it was a second templating syntax (nothing but Ansible's remains), and it rewrote `$word`
inside *every* string — so `echo $HOME` failed with "HOME is undefined" and `awk "{print $2}"` was silently
corrupted to `awk "{print 2}"`. Shell arguments are the most common thing in a runbook; a templating engine
must not touch their `$`. Use `{{ var }}`, and `| default(x, true)` / `| mandatory(msg)` for the modifiers.

A string that is *entirely* one `{{ … }}` expression yields the expression's
native value (so `port: {{ mysql_port }}` stays an int); an embedded placeholder
is stringified. An unresolved variable is an ERROR (StrictUndefined), never a
silent empty string.

Evaluation runs in a jinja2 SandboxedEnvironment — this is the security boundary
against untrusted / LLM-translated input (no arbitrary Python, no attribute
escapes, no dangerous builtins), replacing the old hand-written token whitelist.

Variable scopes merge GPO-style (weakest→strongest) via merge_scopes — the same
precedence the check-assignment resolver uses (global < group < OU < host < role
param < loop item).
"""

from __future__ import annotations

import re
from typing import Any

from jinja2 import ChainableUndefined, StrictUndefined, Undefined
from jinja2.exceptions import TemplateError, UndefinedError
from jinja2.sandbox import SandboxedEnvironment


class NTVarError(Exception):
    """An unresolved / required-but-missing variable reference, or a bad template."""


class StrictChainableUndefined(ChainableUndefined, StrictUndefined):
    """Chains through a missing intermediate (`inventory.gpu.model` where `gpu`
    is absent → an Undefined the `default`/`mandatory` filters can handle), but
    is strict at the point of use: rendering or bare-yielding an undefined value
    is an error, never a silent blank."""


def _mandatory(value: Any, message: str = "mandatory variable is undefined or empty") -> Any:
    """`| mandatory(msg)` — raise if the value is undefined / None / empty, otherwise pass it through."""
    if isinstance(value, Undefined) or value is None or value == "":
        raise NTVarError(message)
    return value


# Sandboxed + strict: an undefined variable is an error, not a blank. autoescape
# off — we render config text and module args, not HTML.
_ENV = SandboxedEnvironment(undefined=StrictChainableUndefined, autoescape=False, keep_trailing_newline=True)
_ENV.filters["mandatory"] = _mandatory

_WHOLE = re.compile(r"^\{\{(?P<e>.*)\}\}$", re.S)


def substitute_str(s: str, vars: dict[str, Any]) -> Any:
    """Substitute one string. Exactly one `{{ … }}` expression → its native value;
    otherwise the interpolated string."""
    stripped = s.strip()
    whole = _WHOLE.match(stripped)
    single = bool(whole) and stripped.count("{{") == 1 and stripped.count("}}") == 1
    try:
        if single:
            value = _ENV.compile_expression(whole.group("e").strip(), undefined_to_none=False)(**vars)  # type: ignore[union-attr]
            if isinstance(value, Undefined):
                raise NTVarError(f"unresolved variable reference in {s!r}")
            return value
        return _ENV.from_string(s).render(**vars)
    except NTVarError:
        raise
    except (UndefinedError, TemplateError) as exc:
        raise NTVarError(f"{exc} (in {s!r})") from exc


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
