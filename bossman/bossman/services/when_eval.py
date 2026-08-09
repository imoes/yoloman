"""Evaluate a step's `when:` condition as a real Ansible/Jinja2 boolean.

This is the pivot to full Ansible semantics: `when:` is now any Jinja2 expression
(`x is defined`, `a == 'b' and c != 'd'`, `x | default(false)`, `item.enabled`),
evaluated exactly the way Ansible does — the string is wrapped in `{{ }}` and its
truthiness taken.

The evaluator runs in a jinja2 SandboxedEnvironment — the security boundary
against untrusted / LLM-translated input (a plan/runbook may be an LLM translation
of an untrusted Ansible role or Salt state). The sandbox blocks arbitrary Python,
attribute escapes and dangerous builtins; it replaces the old hand-written
whitelist grammar. Undefined variables are LENIENT (Ansible-style for `when:`):
a bare undefined name is falsy, `undefined == x` is False, `undefined != x` is
True, and `x is defined` works — so conditions guarding on optional facts don't
explode.

The context is a single flat dict combining resolved params and registered step
results — both share one namespace, mirroring Ansible's variable model.
"""

from __future__ import annotations

from typing import Any

from jinja2 import ChainableUndefined, Undefined
from jinja2.exceptions import TemplateError
from jinja2.sandbox import SandboxedEnvironment

# Lenient, chainable Undefined — not Strict: an undefined var (or a missing
# intermediate like `docker.proxy` when `docker` is absent) is falsy, not an
# error (Ansible's common `when:` usage). `is defined` / `| default` still work.
_ENV = SandboxedEnvironment(autoescape=False, undefined=ChainableUndefined)


class WhenError(Exception):
    """Raised when a when-expression is not valid Jinja or is blocked by the sandbox."""


def eval_when(expr: str, context: dict[str, Any]) -> bool:
    """Evaluate a `when:` expression to a bool. `expr` is a Jinja expression
    (no surrounding `{{ }}` — Ansible-style). Sandbox violations and syntax
    errors raise WhenError."""
    try:
        value = _ENV.compile_expression(str(expr), undefined_to_none=False)(**context)
    except TemplateError as exc:  # syntax error, or SecurityError (subclass) from the sandbox
        raise WhenError(f"invalid when-expression {expr!r}: {exc}") from exc
    if isinstance(value, Undefined):
        # includes sandbox-neutralised unsafe attribute access (e.g. `x.__class__`
        # yields Undefined, not the real class) → treated as falsy
        return False
    return bool(value)
