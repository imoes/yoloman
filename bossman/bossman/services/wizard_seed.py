"""Block 2 — seed one "installation wizard" runbook per catalog package that has
a config template. Each runbook is a three(+)-step procedure — install packages →
render the config from the template → (validate) → enable & restart the service —
with a TYPED `parameters` block (the wizard's input mask) derived from the
template schema (types/defaults/descriptions), enriched with enum values +
authoritative defaults from config_directives.json where the directive name
matches, plus hidden `_packages/_dest/_service` runtime variables.

Idempotent: the generated doc carries a `meta.source_hash`; a package is
re-seeded only when its inputs changed. Callable from a CLI script or app startup.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import DEFAULT_TENANT_ID, Runbook

WIZARD_FOLDER = "wizards"


def _configs_root(settings: Settings) -> Path:
    return Path(settings.config_templates_dir).parent


def _load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def _norm_type(t: Any) -> str:
    t = str(t or "string").lower()
    return "bool" if t == "boolean" else t


def _build_parameters(schema: dict, directives: dict, entry: dict) -> dict[str, Any]:
    """schema {var: {type,default,description,items?}} → typed parameter specs,
    enriched from config_directives (enum values + authoritative default) where a
    directive of the same name exists."""
    params: dict[str, Any] = {}
    for var, spec in schema.items():
        if not isinstance(spec, dict):
            continue
        p: dict[str, Any] = {"type": _norm_type(spec.get("type"))}
        if spec.get("description"):
            p["description"] = spec["description"]
        if spec.get("default") is not None:
            p["default"] = spec["default"]
        if isinstance(spec.get("items"), dict):
            p["items"] = spec["items"]
        # Enrich from the directive catalog (best-effort exact-name match).
        d = directives.get(var)
        if isinstance(d, dict):
            if d.get("type") == "enum" and d.get("values"):
                p["enum"] = d["values"]
            if p.get("default") is None and d.get("default") not in (None, ""):
                p["default"] = d["default"]
            if not p.get("description") and d.get("description"):
                p["description"] = d["description"]
        params[var] = p
    # Hidden runtime variables — Debian defaults (the wizard overrides per family).
    fams = entry.get("families", {})
    fam = fams.get("debian") or fams.get("ubuntu") or (next(iter(fams.values()), {}) if fams else {})
    params["_packages"] = {"type": "list", "hidden": True, "default": fam.get("packages", [])}
    params["_dest"] = {"type": "string", "hidden": True, "default": fam.get("config_path", "")}
    params["_service"] = {"type": "string", "hidden": True, "default": fam.get("service", "")}
    return params


def _build_doc(pkg: str, entry: dict, params: dict, template: str) -> dict:
    """The canonical runbook doc: install → render → (validate) → service."""
    tpl_vars = {v: "${" + v + "}" for v in params if not v.startswith("_")}
    steps: list[dict] = [
        {"name": f"Install {entry.get('label', pkg)}", "module": "package",
         "args": {"name": "${_packages}", "state": "present"}},
        {"name": "Render configuration", "module": "config_template",
         "args": {"template": template, "dest": "${_dest}", "vars": tpl_vars}},
    ]
    if entry.get("validate_cmd"):
        # Runs after the config is written; a non-zero exit aborts the runbook
        # (default ignore_errors=false) BEFORE the service is restarted, so a bad
        # config can't take the service down.
        steps.append({"name": "Validate configuration", "run": entry["validate_cmd"]})
    steps.append({"name": f"Enable and restart {entry.get('label', pkg)}", "module": "service",
                  "args": {"name": "${_service}", "state": "restarted", "enabled": True}})
    return {"kind": "runbook", "name": f"install-{pkg}", "targets": None,
            "parameters": params, "steps": steps}


def _hash(doc: dict) -> str:
    payload = {k: v for k, v in doc.items() if k != "meta"}
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


async def seed_wizard_runbooks(session: AsyncSession, settings: Settings) -> int:
    """Upsert install-<pkg> runbooks for every catalog package with a template.
    Returns the number created or updated."""
    root = _configs_root(settings)
    catalog = _load_json(root / "package_catalog.json")
    directives = _load_json(root / "config_directives.json")
    tdir = Path(settings.config_templates_dir)
    tenant = UUID(str(DEFAULT_TENANT_ID))
    changed = 0
    for pkg, entry in catalog.items():
        template = entry.get("template")
        if not template:
            continue
        schema = _load_json(tdir / template / "schema.json")
        if not schema:
            continue
        params = _build_parameters(schema, directives.get(_dir_key(entry), {}), entry)
        doc = _build_doc(pkg, entry, params, template)
        doc["meta"] = {"source_hash": _hash(doc), "generated": "wizard_seed"}
        name = doc["name"]
        existing = await session.scalar(
            select(Runbook).where(Runbook.tenant_id == tenant, Runbook.name == name)
        )
        if existing is None:
            session.add(Runbook(tenant_id=tenant, name=name, kind="runbook",
                                folder=WIZARD_FOLDER, doc=doc, created_by="wizard-seed"))
            changed += 1
        elif (existing.doc or {}).get("meta", {}).get("source_hash") != doc["meta"]["source_hash"]:
            existing.doc = doc
            existing.folder = WIZARD_FOLDER
            changed += 1
    if changed:
        await session.commit()
    return changed


def _dir_key(entry: dict) -> str:
    """config_directives.json is keyed by config-file basename — derive it from
    the debian config_path (e.g. /etc/ssh/sshd_config → sshd_config)."""
    path = entry.get("families", {}).get("debian", {}).get("config_path", "")
    return Path(path).name if path else ""
