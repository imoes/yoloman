"""Publish the package catalogue as versioned desired-state artifacts.

The installation wizard's generated runbooks remain the executable source,
but operators and deployments see one canonical OrchestrationPlan per catalog
role/feature.  Hash-based upserts make startup and periodic reseeding safe.
"""

from __future__ import annotations

import json
import hashlib
from pathlib import Path
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import DEFAULT_TENANT_ID, OrchestrationPlan, OrchestrationPlanVersion, Runbook
from bossman.api.config_templates import family_key, load_template_bodies, target_key
from bossman.services.nt_runbook import Role


def artifact_name(package_name: str) -> str:
    return f"catalog__{package_name}"


def _parameter_parts(raw: dict) -> tuple[dict, dict]:
    schema: dict = {}
    defaults: dict = {}
    for name, value in (raw or {}).items():
        if isinstance(value, dict) and "type" in value:
            schema[name] = dict(value)
            if "default" in value:
                defaults[name] = value["default"]
        else:
            defaults[name] = value
    return schema, defaults


def _generic_catalog_doc(package_name: str, entry: dict) -> dict:
    """Executable fallback for package-only and Windows catalogue entries."""
    return {
        "kind": "runbook",
        "name": f"install-{package_name}",
        "parameters": {},
        "steps": [
            {
                "name": f"Install {entry.get('label') or package_name}",
                "module": "package",
                "args": {"name": "{{ _packages }}", "state": "present"},
                "when": "_packages",
            },
            {
                # The family's one-time initialisation (catalog `families.<f>.init`, idempotent itself) — see
                # wizard_seed._with_init.
                "name": f"Initialise {entry.get('label') or package_name}",
                "run": "{{ _init }}",
                "when": "_packages and _init",
            },
            {
                "name": f"Install Windows features for {entry.get('label') or package_name}",
                "module": "windows_feature",
                "args": {
                    "name": "{{ _features }}", "state": "present",
                    "include_management_tools": "{{ _include_management_tools }}",
                },
                "when": "_features",
            },
            {
                "name": f"Enable {entry.get('label') or package_name}",
                "module": "service",
                "args": {"name": "{{ _service }}", "state": "started", "enabled": "{{ _enable }}", "masked": False},
                "when": "_packages and _service",
            },
        ],
    }


def _template_snapshot(
    settings,
    steps: list[dict],
    *,
    available: dict[str, str] | None = None,
) -> dict[str, str]:
    names: set[str] = set()

    def visit(rows: list[dict]) -> None:
        for step in rows or []:
            if step.get("module") == "config_template":
                name = (step.get("args") or {}).get("template")
                if isinstance(name, str) and "{{" not in name and "${" not in name:
                    names.add(name)
            for key in ("block", "rescue", "always"):
                visit(step.get(key) or [])

    visit(steps)
    # Loading the complete template library is deliberately injectable here.
    # Catalog seeding calls this function once per role/feature and the library
    # is several megabytes, so re-reading it for every artifact used to hold the
    # ASGI lifespan in startup for minutes.
    if available is None:
        available = load_template_bodies(settings)
    return {name: available[name] for name in sorted(names) if name in available}


async def seed_catalog_artifacts(session: AsyncSession, settings) -> int:
    """Create/update one system-managed role/feature plan per catalog item."""
    path = Path(settings.config_templates_dir).parent / "package_catalog.json"
    try:
        catalog = json.loads(path.read_text())
    except (OSError, ValueError):
        return 0

    tenant = UUID(str(DEFAULT_TENANT_ID))
    changed = 0
    template_bodies = load_template_bodies(settings)
    for package_name, entry in catalog.items():
        kind = entry.get("kind", "feature")
        if kind not in ("role", "feature"):
            continue
        rb = await session.scalar(
            select(Runbook).where(
                Runbook.tenant_id == tenant,
                Runbook.name == f"install-{package_name}",
            )
        )
        doc = (rb.doc or {}) if rb is not None else _generic_catalog_doc(package_name, entry)
        doc_hash = (doc.get("meta") or {}).get("source_hash") if rb is not None else None
        artifact_templates = _template_snapshot(
            settings,
            doc.get("steps") or [],
            available=template_bodies,
        )
        # Each family branch's own template for its config file travels with the version too, so a RedHat
        # target renders the RedHat file (nt_engine picks "@<family>:<dest>" first).
        if artifact_templates:
            for name in list(artifact_templates):
                if target_key(name) in template_bodies:
                    artifact_templates[target_key(name)] = template_bodies[target_key(name)]
            for fam, branch in (entry.get("families") or {}).items():
                key = family_key(fam, (branch or {}).get("config_path") or "") if isinstance(branch, dict) else ""
                if key in template_bodies:
                    artifact_templates[key] = template_bodies[key]
        source_hash = hashlib.sha256(json.dumps({
            "doc_hash": doc_hash,
            "doc": None if doc_hash else doc,
            # Package/feature names are executable content and therefore part
            # of the immutable version, not a live catalog lookup later.
            "families": entry.get("families") or {},
            "kind": kind,
            "template_bodies": artifact_templates,
        }, sort_keys=True, default=str).encode()).hexdigest()

        name = artifact_name(package_name)
        plan = await session.scalar(
            select(OrchestrationPlan).where(
                OrchestrationPlan.tenant_id == tenant,
                OrchestrationPlan.name == name,
                OrchestrationPlan.deleted_at.is_(None),
            )
        )
        if plan is None:
            plan = OrchestrationPlan(
                id=uuid4(), tenant_id=tenant, name=name,
                display_name=entry.get("label") or package_name,
                description=entry.get("description") or "",
                plan_type=kind, current_version=0, created_by="catalog-seed",
            )
            session.add(plan)
            await session.flush()
        display_name = entry.get("label") or package_name
        description = entry.get("description") or ""
        metadata_changed = (
            plan.plan_type != kind or plan.display_name != display_name or plan.description != description
        )
        plan.plan_type = kind
        plan.display_name = display_name
        plan.description = description
        current = None
        if plan.current_version:
            current = await session.scalar(
                select(OrchestrationPlanVersion).where(
                    OrchestrationPlanVersion.plan_id == plan.id,
                    OrchestrationPlanVersion.version == plan.current_version,
                )
            )
        if current and (current.requirements or {}).get("source_hash") == source_hash:
            if metadata_changed:
                changed += 1
            continue

        schema, defaults = _parameter_parts(doc.get("parameters") or {})
        version = plan.current_version + 1
        has_service = any(bool(branch.get("service")) for branch in (entry.get("families") or {}).values())
        session.add(OrchestrationPlanVersion(
            id=uuid4(), tenant_id=tenant, plan_id=plan.id, version=version,
            parameter_schema=schema, default_parameters=defaults,
            requirements={
                "source": "package_catalog", "source_hash": source_hash,
                "catalog_name": package_name, "catalog_kind": kind,
                "catalog_families": entry.get("families") or {},
                "template_bodies": artifact_templates,
            },
            steps=doc.get("steps") or [], rollback_steps=[], validation_steps=[],
            generated_monitoring={"checks": ["service_health"] if kind == "role" and has_service else []},
            generated_notifications={}, created_by="catalog-seed",
        ))
        plan.current_version = version
        changed += 1
    if changed:
        await session.commit()
    return changed


async def publish_authored_role(session: AsyncSession, role: Role, *, actor: str,
                                source_runbook_id=None, settings=None) -> OrchestrationPlan:
    """Upsert an authored role as a new immutable artifact version.

    Existing deployments remain pinned to their old version; publishing never
    changes a host by itself.
    """
    tenant = UUID(str(DEFAULT_TENANT_ID))
    doc = role.to_dict()
    template_bodies = _template_snapshot(settings, doc.get("steps") or []) if settings is not None else {}
    source_hash = hashlib.sha256(
        json.dumps({"doc": doc, "template_bodies": template_bodies},
                   sort_keys=True, default=str, separators=(",", ":")).encode()
    ).hexdigest()
    plan = await session.scalar(select(OrchestrationPlan).where(
        OrchestrationPlan.tenant_id == tenant,
        OrchestrationPlan.name == role.name,
        OrchestrationPlan.deleted_at.is_(None),
    ))
    if plan is None:
        plan = OrchestrationPlan(
            id=uuid4(), tenant_id=tenant, name=role.name,
            display_name=role.name.replace("_", " ").title(),
            description=role.description, plan_type="role", current_version=0,
            created_by=actor,
        )
        session.add(plan)
        await session.flush()
    elif plan.plan_type not in ("role", "feature"):
        raise ValueError(f"an orchestration plan named {role.name!r} already exists and is {plan.plan_type}")
    current = None
    if plan.current_version:
        current = await session.scalar(select(OrchestrationPlanVersion).where(
            OrchestrationPlanVersion.plan_id == plan.id,
            OrchestrationPlanVersion.version == plan.current_version,
        ))
    if current and (current.requirements or {}).get("source_hash") == source_hash:
        return plan
    schema, defaults = _parameter_parts(role.parameters)
    version = plan.current_version + 1
    session.add(OrchestrationPlanVersion(
        id=uuid4(), tenant_id=tenant, plan_id=plan.id, version=version,
        parameter_schema=schema, default_parameters=defaults,
        requirements={"source": "runbook-role", "source_hash": source_hash,
                      "source_runbook_id": str(source_runbook_id) if source_runbook_id else None,
                      "template_bodies": template_bodies},
        steps=[s.to_dict() for s in role.steps], rollback_steps=[], validation_steps=[],
        generated_monitoring={"checks": list(role.checks)},
        generated_notifications={"routes": list(role.notification_routes)},
        created_by=actor,
    ))
    plan.description = role.description
    plan.current_version = version
    plan.updated_by = actor
    await session.flush()
    return plan


__all__ = ["artifact_name", "seed_catalog_artifacts", "publish_authored_role"]
