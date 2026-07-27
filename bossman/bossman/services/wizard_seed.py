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

import asyncio
import hashlib
import json
import logging
from pathlib import Path
from typing import Any
from uuid import UUID

import yaml
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import DEFAULT_TENANT_ID, Runbook
from bossman.services import ansible_playbook

WIZARD_FOLDER = "wizards"


def _configs_root(settings: Settings) -> Path:
    return Path(settings.config_templates_dir).parent


def _playbooks_dir(settings: Settings) -> Path:
    return _configs_root(settings) / "wizard_playbooks"


def _infer_type(value: Any) -> str:
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, list):
        return "list"
    if isinstance(value, dict):
        return "object"
    return "string"


def _params_from_play_vars(play_vars: dict[str, Any], schema_params: dict[str, Any]) -> dict[str, Any]:
    """Build the wizard input mask from the playbook's own `vars:` block — the
    playbook is now the source of truth. Each var → a typed parameter with that
    default; `_`-prefixed vars stay hidden runtime values. Where a same-named
    schema parameter exists, its richer metadata (enum / description) is merged
    in on top."""
    params: dict[str, Any] = {}
    for name, value in play_vars.items():
        p: dict[str, Any] = {"type": _infer_type(value), "default": value}
        if name.startswith("_"):
            p["hidden"] = True
        sp = schema_params.get(name)
        if isinstance(sp, dict):
            if sp.get("enum"):
                p["enum"] = sp["enum"]
            if sp.get("description"):
                p["description"] = sp["description"]
        params[name] = p
    return params


def _fam(entry: dict) -> dict:
    fams = entry.get("families", {})
    return fams.get("debian") or fams.get("ubuntu") or (next(iter(fams.values()), {}) if fams else {})


# The native template render (`ansible.builtin.template` / `template`) can't be
# used as-is: the .j2 lives in Bossman's config-template catalog, not on the
# agent. Re-map such steps to the Bossman `config_template` module (the working
# render path), with vars wired to the runbook parameters so the wizard form
# actually flows into the rendered config.
_TEMPLATE_MODULES = {"template", "ansible.builtin.template"}


def _remap_template_step(step: dict[str, Any], param_names: list[str]) -> dict[str, Any]:
    args = step.get("args") or {}
    src = str(args.get("src", ""))
    if step.get("module") not in _TEMPLATE_MODULES or not src.endswith(".j2"):
        return step
    render_vars = {v: "{{ " + v + " }}" for v in param_names if not v.startswith("_")}
    out: dict[str, Any] = {
        "name": step.get("name", ""), "module": "config_template",
        "args": {"template": src[:-3], "dest": args.get("dest") or "{{ _dest }}", "vars": render_vars},
    }
    for key in ("when", "loop", "register", "ignore_errors", "become", "tags", "notify"):
        if key in step and step[key] not in (None, [], {}, False):
            out[key] = step[key]
    return out


def _doc_from_playbook(pkg: str, text: str, entry: dict, schema_params: dict[str, Any]) -> dict:
    """Parse a generated Ansible playbook into the canonical runbook doc: steps +
    handlers from the playbook, the input mask from its play vars. The native
    template step is re-mapped to `config_template`, and the hidden runtime vars
    (_packages/_dest/_service) are guaranteed from the catalog so `{{ _packages }}`
    style references always resolve."""
    rb = ansible_playbook.parse_playbook(text)
    raw = yaml.safe_load(text)
    play = raw[0] if isinstance(raw, list) else raw
    play_vars = (play or {}).get("vars", {}) if isinstance(play, dict) else {}
    params = _params_from_play_vars(play_vars, schema_params)
    # Hidden runtime vars from the catalog (Debian family) — fill any the
    # playbook referenced but didn't define, so StrictUndefined never trips.
    fam = _fam(entry)
    params.setdefault("_packages", {"type": "list", "hidden": True, "default": fam.get("packages", [])})
    params.setdefault("_dest", {"type": "string", "hidden": True, "default": fam.get("config_path", "")})
    params.setdefault("_service", {"type": "string", "hidden": True, "default": fam.get("service", "")})
    names = list(params)
    steps = [_remap_template_step(s.to_dict(), names) for s in rb.steps]
    doc: dict[str, Any] = {
        "kind": "runbook", "name": f"install-{pkg}", "targets": None,
        "parameters": params, "steps": steps,
    }
    if rb.handlers:
        doc["handlers"] = [h.to_dict() for h in rb.handlers]
    return doc


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
        # Schema-level enum is authoritative (enrich_schema_enums already merged
        # ADMX + curated choices into the schema) — carry it into the mask so the
        # wizard renders a dropdown.
        if spec.get("enum"):
            p["enum"] = spec["enum"]
        # Enrich from the directive catalog (best-effort exact-name match) for
        # any field the schema didn't already mark.
        d = directives.get(var)
        if isinstance(d, dict):
            if not p.get("enum") and d.get("type") == "enum" and d.get("values"):
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
    pbdir = _playbooks_dir(settings)
    tenant = UUID(str(DEFAULT_TENANT_ID))
    changed = 0
    for pkg, entry in catalog.items():
        template = entry.get("template")
        if not template:
            continue
        # Schema drives the input mask for the fallback build and enriches the
        # playbook's params; it's optional when a generated playbook exists (the
        # playbook carries its own vars).
        schema = _load_json(tdir / template / "schema.json")
        schema_params = _build_parameters(schema, directives.get(_dir_key(entry), {}), entry) if schema else {}
        pbfile = pbdir / f"install-{pkg}.yml"
        # Prefer the generated Ansible playbook (the adopted source of truth).
        if pbfile.is_file():
            try:
                doc = _doc_from_playbook(pkg, pbfile.read_text(), entry, schema_params)
                source = "playbook"
            except Exception:  # noqa: BLE001 — a bad playbook falls back, never crashes seeding
                logger.warning("wizard seed: playbook %s unusable, falling back to build", pbfile.name, exc_info=True)
                if not schema:
                    continue
                doc = _build_doc(pkg, entry, schema_params, template)
                source = "wizard_seed"
        elif schema:
            doc = _build_doc(pkg, entry, schema_params, template)
            source = "wizard_seed"
        else:
            continue  # no playbook and no schema → nothing to seed
        doc["meta"] = {"source_hash": _hash(doc), "generated": source}
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
    fams = entry.get("families", {})
    fam = fams.get("debian") or fams.get("ubuntu") or (next(iter(fams.values()), {}) if fams else {})
    path = fam.get("config_path", "")
    return Path(path).name if path else ""


logger = logging.getLogger(__name__)


async def wizard_reseed_loop(session_factory, settings: Settings, stop_event: asyncio.Event,
                             interval: float = 900.0) -> None:
    """Periodically re-seed wizard runbooks so packages whose template the batch
    just generated become installable roles without a bossman restart.
    Idempotent hash-upsert; best-effort."""
    while not stop_event.is_set():
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval)
            return  # stop requested
        except asyncio.TimeoutError:
            pass
        try:
            async with session_factory() as session:
                n = await seed_wizard_runbooks(session, settings)
                if n:
                    logger.info("wizard reseed: %d runbook(s) added/updated", n)
        except Exception:  # noqa: BLE001 — never let reseed crash the loop
            logger.warning("wizard reseed failed", exc_info=True)
