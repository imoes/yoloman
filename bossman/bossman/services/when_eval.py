"""A tiny, deliberately non-Turing-complete expression evaluator for a
plan step's `when:` condition (see docs/plan.md's Ansible-ingestion plan)
— NOT a Jinja2 or eval() implementation. Real Ansible `when:` clauses can
call arbitrary Jinja2 filters; that is explicitly out of scope here, and
not just as a scoping cut: a plan file may originate from an LLM
translation of an untrusted source (an Ansible role, a Salt state), so
evaluating a small whitelisted grammar rather than eval()ing arbitrary
text is a deliberate security boundary.

Supported grammar (each line is a complete `when:` value):
    not <expr>
    <path> is defined
    <path> is not defined
    <path> == <literal>
    <path> != <literal>
    <path>                      (bare truthy check)

<path> is a dotted identifier chain (`docker.proxy`,
`_containerd_dir.data.exists`) resolved against a single flat context dict
that combines resolved plan params and registered step results — both
share one namespace, mirroring Ansible's own variable model where a
registered result is just another variable.
"""

from __future__ import annotations

import re
from typing import Any

_IS_NOT_DEFINED_RE = re.compile(r"^(?P<path>[\w.]+)\s+is\s+not\s+defined$")
_IS_DEFINED_RE = re.compile(r"^(?P<path>[\w.]+)\s+is\s+defined$")
_EQ_RE = re.compile(r"^(?P<path>[\w.]+)\s*==\s*(?P<literal>.+)$")
_NEQ_RE = re.compile(r"^(?P<path>[\w.]+)\s*!=\s*(?P<literal>.+)$")
_BARE_PATH_RE = re.compile(r"^[\w.]+$")

_UNRESOLVED = object()  # sentinel distinguishing "path resolves to None" from "path doesn't exist"


class WhenError(Exception):
    """Raised when a when-expression falls outside this evaluator's limited grammar."""


def _resolve_path(path: str, context: dict[str, Any]) -> Any:
    value: Any = context
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            return _UNRESOLVED
        value = value[part]
    return value


def _parse_literal(text: str) -> Any:
    text = text.strip()
    if text == "true":
        return True
    if text == "false":
        return False
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
        return text[1:-1]
    try:
        return int(text)
    except ValueError:
        pass
    try:
        return float(text)
    except ValueError:
        pass
    raise WhenError(f"cannot parse literal {text!r}")


def eval_when(expr: str, context: dict[str, Any]) -> bool:
    expr = expr.strip()

    if expr.startswith("not "):
        return not eval_when(expr[4:], context)

    m = _IS_NOT_DEFINED_RE.match(expr)
    if m:
        return _resolve_path(m.group("path"), context) is _UNRESOLVED

    m = _IS_DEFINED_RE.match(expr)
    if m:
        return _resolve_path(m.group("path"), context) is not _UNRESOLVED

    m = _EQ_RE.match(expr)
    if m:
        value = _resolve_path(m.group("path"), context)
        return value is not _UNRESOLVED and value == _parse_literal(m.group("literal"))

    m = _NEQ_RE.match(expr)
    if m:
        value = _resolve_path(m.group("path"), context)
        return value is _UNRESOLVED or value != _parse_literal(m.group("literal"))

    if _BARE_PATH_RE.match(expr):
        value = _resolve_path(expr, context)
        return bool(value) if value is not _UNRESOLVED else False

    raise WhenError(
        f"unsupported when-expression {expr!r} — only 'not', 'is defined', 'is not defined', "
        "'==', '!=', and a bare dotted path are supported"
    )
