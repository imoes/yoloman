"""Credential provisioning for checks (Block G9-P3d).

Some checks need an account to monitor with (a MySQL monitoring user, an
SNMP community, …). A check MAY ship a provisioning recipe alongside it —
`checks.d/<name>.provision.nt` (NestedText, like the module metadata) —
describing how to create that account on the host and which of the check's
params the result fills. The wizard runs it: the operator supplies the
*admin* credentials (used only to create the monitoring account), the recipe
generates the monitoring secret, runs the setup command on the host via the
agent's `command` module, and returns the check params (monitoring user +
generated password) to store on the assignment. The admin credentials are
never persisted.

Recipe shape (checks.d/mysql.provision.nt) — NestedText, all values are
strings/lists/dicts (no quoting, no YAML):

    check: mysql
    title: Create a MySQL monitoring user
    admin_params:
      admin_user: MySQL admin user (e.g. root)
      admin_password: MySQL admin password
    secret_params:
      - admin_password
    generate:
      - monitor_password
    argv:
      - mysql
      - -u{admin_user}
      - -p{admin_password}
      - -e
      - CREATE USER IF NOT EXISTS 'monitor'@'localhost' IDENTIFIED BY '{monitor_password}'; ...
    produces:
      user: monitor
      password: {monitor_password}
"""

from __future__ import annotations

import secrets
from pathlib import Path
from typing import Any

import nestedtext
import yaml


def recipe_path(checks_dir: str | Path, name: str) -> Path:
    """The recipe sidecar: `.provision.yaml`, or the legacy `.provision.nt` while a tree is unconverted."""
    base = Path(checks_dir)
    yml = base / f"{name}.provision.yaml"
    nt = base / f"{name}.provision.nt"
    return nt if not yml.exists() and nt.exists() else yml


def load_recipe(checks_dir: str | Path, name: str) -> dict[str, Any] | None:
    """The provisioning recipe for a check, or None if it ships none / is unparseable."""
    p = recipe_path(checks_dir, name)
    if not p.exists():
        return None
    try:
        text = p.read_text(encoding="utf-8")
        r = nestedtext.loads(text, top="dict") if p.suffix == ".nt" else yaml.safe_load(text)
    except (OSError, yaml.YAMLError, nestedtext.NestedTextError):
        return None
    return r if isinstance(r, dict) else None


def admin_param_specs(recipe: dict[str, Any]) -> list[dict[str, Any]]:
    """The admin params the wizard must collect, as [{name, description,
    secret}]. admin_params is a NestedText dict name->description; a name in
    secret_params is masked in the UI."""
    secret = set(recipe.get("secret_params") or [])
    specs = []
    for name, desc in (recipe.get("admin_params") or {}).items():
        specs.append({"name": name, "description": desc or "", "required": True, "secret": name in secret})
    return specs


def _subst(template: str, values: dict[str, str]) -> str:
    """Replace every {key} in template with values[key] (literal replace, so
    SQL braces or % are never treated as format specifiers)."""
    out = template
    for k, v in values.items():
        out = out.replace("{" + k + "}", str(v))
    return out


async def provision(client, recipe: dict[str, Any], admin_params: dict[str, Any]) -> dict[str, Any]:
    """Run the recipe on the host: mint the generated secrets, render + run
    the setup command via the agent `command` module, and return
    {ok, produced_params, output, error}. `produced_params` is what to store
    on the check assignment; admin_params are used only here and never
    returned/persisted."""
    required = list((recipe.get("admin_params") or {}).keys())
    missing = [n for n in required if not admin_params.get(n)]
    if missing:
        return {"ok": False, "error": "missing required admin params: " + ", ".join(missing), "produced_params": {}, "output": ""}

    values: dict[str, str] = {k: str(v) for k, v in admin_params.items()}
    for gen in recipe.get("generate", []) or []:
        values[gen] = secrets.token_urlsafe(18)

    argv = [_subst(str(a), values) for a in recipe.get("argv", []) or []]
    if not argv:
        return {"ok": False, "error": "recipe has no argv command", "produced_params": {}, "output": ""}

    try:
        result = await client.call_tool("command", {"argv": argv})
    except Exception as exc:  # noqa: BLE001 — surface as a failed provisioning, never raise
        return {"ok": False, "error": "command failed: %s" % exc, "produced_params": {}, "output": ""}

    data = (result or {}).get("data") if isinstance(result, dict) else {}
    rc = (data or {}).get("rc", 0) if isinstance(data, dict) else 0
    output = ((data or {}).get("stdout", "") + (data or {}).get("stderr", "")) if isinstance(data, dict) else ""
    if rc not in (0, None):
        return {"ok": False, "error": "setup command exited %s" % rc, "produced_params": {}, "output": output[:2000]}

    produced = {k: _subst(str(v), values) for k, v in (recipe.get("produces") or {}).items()}
    return {"ok": True, "error": "", "produced_params": produced, "output": output[:2000]}
