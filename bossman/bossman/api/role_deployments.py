"""SCCM-style deployment API for desired-state roles and features."""

from __future__ import annotations

from typing import Any
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import (
    DEFAULT_TENANT_ID,
    Agent,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OrchestrationPlanVersion,
    RoleDeployment,
    RoleDeploymentItem,
    RoleDeploymentTarget,
)
from bossman.db.session import get_session
from bossman.services.auth import Identity, user_can_manage_agent
from bossman.services.compiler import compile_host_desired_state
from bossman.services.role_catalog import artifact_name
from bossman.services.role_deployment import (
    PILOT_THRESHOLD,
    catalog_family_note,
    catalog_runtime,
    deployment_preview_hash,
    pilot_wait_reason,
    process_deployment_once,
    resolve_scope,
    sync_targets,
    target_hash,
)

router = APIRouter()
TENANT = UUID(str(DEFAULT_TENANT_ID))


class TargetIn(BaseModel):
    type: str
    id: UUID | None = None


class DeploymentItemIn(BaseModel):
    plan_id: UUID | None = None
    catalog_name: str | None = None
    plan_version: int | None = None
    parameters: dict[str, Any] = Field(default_factory=dict)


class DeploymentPreviewIn(BaseModel):
    target: TargetIn
    items: list[DeploymentItemIn]
    pilot_enabled: bool | None = None


class DeploymentCreateIn(DeploymentPreviewIn):
    name: str
    preview_hash: str
    require_approval: bool | None = None


class RemediateIn(BaseModel):
    target_ids: list[UUID] = Field(default_factory=list)


class RetireIn(BaseModel):
    behavior: str = "unmanage"


async def _uninstall_action(
    session: AsyncSession, target: RoleDeploymentTarget, settings: Settings,
) -> tuple[Agent, str, dict]:
    """Resolve an explicit, reversible-as-possible catalog uninstall action."""
    item = await session.get(RoleDeploymentItem, target.item_id)
    agent = await session.get(Agent, target.agent_id)
    version = await session.scalar(select(OrchestrationPlanVersion).where(
        OrchestrationPlanVersion.plan_id == item.plan_id,
        OrchestrationPlanVersion.version == item.plan_version,
    )) if item else None
    package_name = (version.requirements or {}).get("catalog_name") if version else None
    if not package_name or agent is None or not agent.address:
        raise HTTPException(422, "this target has no reachable catalog-backed uninstall action")
    from bossman.api.package_wizard import _catalog, _family, _resolve_family

    families = (version.requirements or {}).get("catalog_families")
    if families is None:
        families = (_catalog(settings).get(package_name) or {}).get("families") or {}
    branch, meta = _resolve_family(families, _family(agent.facts or {}))
    if not meta.get("installable"):
        raise HTTPException(422, meta.get("reason") or "catalog item is not applicable")
    packages = branch.get("packages") or []
    features = branch.get("features") or []
    if packages:
        return agent, "package", {"name": packages, "state": "absent"}
    if features:
        return agent, "windows_feature", {"name": features, "state": "absent"}
    raise HTTPException(422, "no packages or Windows features are resolved for uninstall")


async def _ensure_manage_ids(session: AsyncSession, identity: Identity, agent_ids: list[UUID]) -> None:
    for agent_id in agent_ids:
        if not await user_can_manage_agent(session, identity, agent_id):
            raise HTTPException(403, "not authorized to manage every host in this deployment")


async def _deployment_agent_ids(session: AsyncSession, deployment_id: UUID) -> list[UUID]:
    return list((await session.scalars(
        select(RoleDeploymentTarget.agent_id)
        .where(RoleDeploymentTarget.deployment_id == deployment_id)
        .distinct()
    )).all())


async def _ensure_manage_deployment(
    session: AsyncSession, identity: Identity, deployment_id: UUID,
) -> None:
    await _ensure_manage_ids(session, identity, await _deployment_agent_ids(session, deployment_id))


def _scope_kwargs(target: TargetIn) -> dict:
    if target.type not in ("host", "group", "ou", "site", "global"):
        raise HTTPException(422, "target.type must be host|group|ou|site|global")
    if target.type != "global" and target.id is None:
        raise HTTPException(422, f"target {target.type!r} needs an id")
    return {
        "agent_id": target.id if target.type == "host" else None,
        "host_group_id": target.id if target.type == "group" else None,
        "ou_id": target.id if target.type == "ou" else None,
        "site_id": target.id if target.type == "site" else None,
    }


async def _resolve_item(session: AsyncSession, body: DeploymentItemIn) -> tuple[OrchestrationPlan, OrchestrationPlanVersion]:
    plan = None
    if body.plan_id:
        plan = await session.get(OrchestrationPlan, body.plan_id)
    elif body.catalog_name:
        plan = await session.scalar(select(OrchestrationPlan).where(
            OrchestrationPlan.tenant_id == TENANT,
            OrchestrationPlan.name == artifact_name(body.catalog_name),
            OrchestrationPlan.deleted_at.is_(None),
        ))
    if plan is None or plan.deleted_at is not None:
        raise HTTPException(422, detail=f"no deployable artifact for {body.catalog_name or body.plan_id}")
    if plan.plan_type not in ("role", "feature"):
        raise HTTPException(422, detail=f"{plan.name!r} is {plan.plan_type}, not a role or feature")
    version_no = body.plan_version or plan.current_version
    version = await session.scalar(select(OrchestrationPlanVersion).where(
        OrchestrationPlanVersion.plan_id == plan.id,
        OrchestrationPlanVersion.version == version_no,
    ))
    if version is None:
        raise HTTPException(422, detail=f"no version {version_no} of {plan.name!r}")
    return plan, version


def _validate_parameters(version: OrchestrationPlanVersion, supplied: dict[str, Any]) -> None:
    schema = version.parameter_schema or {}
    unknown = set(supplied) - set(schema)
    if unknown:
        raise HTTPException(422, f"unknown role parameter(s): {', '.join(sorted(unknown))}")
    hidden = [name for name in supplied if name.startswith("_") or (schema.get(name) or {}).get("hidden")]
    if hidden:
        raise HTTPException(422, f"runtime role parameter(s) cannot be overridden: {', '.join(sorted(hidden))}")
    merged = {**(version.default_parameters or {}), **supplied}
    python_types = {
        "string": str, "number": (int, float), "int": int,
        "bool": bool, "list": list, "object": dict,
    }
    # Every missing required value at once: naming one per attempt makes the operator fix the form three times
    # (iodined needs tunnel_ip, topdomain and password — values only the site has).
    missing = sorted(name for name, spec in schema.items()
                     if isinstance(spec, dict) and not spec.get("hidden") and spec.get("required")
                     and merged.get(name) in (None, "", [], {}))   # an empty list of subnets is no subnet
    if missing:
        raise HTTPException(422, ("required role parameter {} is missing" if len(missing) == 1
                                  else "required role parameters {} are missing").format(
                                      ", ".join(repr(m) for m in missing)))
    for name, spec in schema.items():
        if not isinstance(spec, dict) or spec.get("hidden"):
            continue
        value = merged.get(name)
        if value is None:
            continue
        expected = python_types.get(spec.get("type"))
        if expected and (
            not isinstance(value, expected)
            or (spec.get("type") in ("number", "int") and isinstance(value, bool))
        ):
            raise HTTPException(422, f"role parameter {name!r} must be {spec.get('type')}")
        if spec.get("enum") and value not in spec["enum"]:
            raise HTTPException(422, f"role parameter {name!r} must be one of {spec['enum']}")


async def _preview(session: AsyncSession, settings: Settings, body: DeploymentPreviewIn) -> dict:
    if not body.items:
        raise HTTPException(422, "at least one role or feature is required")
    kw = _scope_kwargs(body.target)
    ids = await resolve_scope(session, TENANT, body.target.type, **kw)
    if not ids:
        raise HTTPException(422, "target scope matched no hosts")
    agents = {a.id: a for a in (await session.scalars(select(Agent).where(Agent.id.in_(ids)))).all()}
    artifacts = []
    locked_items = []
    applicability = []
    for item in body.items:
        plan, version = await _resolve_item(session, item)
        _validate_parameters(version, item.parameters)
        artifacts.append({
            "plan_id": str(plan.id), "name": plan.name, "display_name": plan.display_name,
            "kind": plan.plan_type, "version": version.version,
        })
        locked_items.append({
            "plan_id": str(plan.id), "version": version.version,
            "parameters": item.parameters,
        })
        unavailable = []
        substituted = []
        for agent_id in ids:
            agent = agents.get(agent_id)
            if agent is None:
                unavailable.append({"agent_id": str(agent_id), "host": None, "reason": "host no longer exists"})
                continue
            _runtime, reason = catalog_runtime(settings, agent, version)
            if reason:
                unavailable.append({"agent_id": str(agent.id), "host": agent.name, "reason": reason})
            elif note := catalog_family_note(settings, agent, version):
                substituted.append({"agent_id": str(agent.id), "host": agent.name, "reason": note})
        applicability.append({
            "plan_id": str(plan.id), "name": plan.name,
            "applicable_host_count": len(ids) - len(unavailable),
            "not_applicable": unavailable,
            # Applicable only by borrowing another family's package names — counted as applicable, said apart.
            "substituted": substituted,
        })
    if len({item["plan_id"] for item in locked_items}) != len(locked_items):
        raise HTTPException(422, "a role or feature can appear only once in a deployment")
    requires_approval = body.target.type == "global" or len(ids) > PILOT_THRESHOLD
    pilot = (len(ids) > PILOT_THRESHOLD) if body.pilot_enabled is None else body.pilot_enabled
    pilot_enabled = bool(pilot and len(ids) > 1)
    return {
        "preview_hash": deployment_preview_hash(ids, locked_items, pilot_enabled),
        "target_hash": target_hash(ids), "affected_host_count": len(ids),
        "agent_ids": [str(x) for x in ids], "artifacts": artifacts,
        "approval_required": requires_approval, "pilot_enabled": pilot_enabled,
        "pilot_agent_id": str(ids[0]) if pilot and len(ids) > 1 else None,
        "applicability": applicability,
    }


@router.get("/api/v1/role-artifacts")
async def list_artifacts(session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)) -> dict:
    plans = (await session.scalars(select(OrchestrationPlan).where(
        OrchestrationPlan.tenant_id == TENANT,
        OrchestrationPlan.plan_type.in_(("role", "feature")),
        OrchestrationPlan.enabled.is_(True), OrchestrationPlan.deleted_at.is_(None),
    ).order_by(OrchestrationPlan.display_name))).all()
    versions = (await session.scalars(
        select(OrchestrationPlanVersion)
        .join(OrchestrationPlan, OrchestrationPlan.id == OrchestrationPlanVersion.plan_id)
        .where(
            OrchestrationPlan.tenant_id == TENANT,
            OrchestrationPlanVersion.version == OrchestrationPlan.current_version,
        )
    )).all()
    current = {version.plan_id: version for version in versions}
    return {"artifacts": [{
        "id": str(p.id), "name": p.name, "display_name": p.display_name,
        "description": p.description, "kind": p.plan_type, "current_version": p.current_version,
        "parameter_schema": current[p.id].parameter_schema if p.id in current else {},
        "default_parameters": current[p.id].default_parameters if p.id in current else {},
    } for p in plans]}


@router.post("/api/v1/role-deployments/preview")
async def preview(body: DeploymentPreviewIn, session: AsyncSession = Depends(get_session),
                  settings: Settings = Depends(get_settings),
                  identity: Identity = Depends(get_current_identity)) -> dict:
    result = await _preview(session, settings, body)
    await _ensure_manage_ids(session, identity, [UUID(value) for value in result["agent_ids"]])
    return result


@router.post("/api/v1/role-deployments")
async def create(body: DeploymentCreateIn, session: AsyncSession = Depends(get_session),
                 settings: Settings = Depends(get_settings),
                 identity: Identity = Depends(get_current_identity)) -> dict:
    if not body.name.strip():
        raise HTTPException(422, "name is required")
    p = await _preview(session, settings, body)
    await _ensure_manage_ids(session, identity, [UUID(value) for value in p["agent_ids"]])
    if p["preview_hash"] != body.preview_hash:
        raise HTTPException(409, "target membership changed since preview; preview again")
    policy_requires = bool(p["approval_required"] or identity.kind != "user" or identity.role != "admin")
    approval = policy_requires if body.require_approval is None else bool(body.require_approval or policy_requires)
    status = "pending_approval" if approval else "active"
    kw = _scope_kwargs(body.target)
    resolved_items = [await _resolve_item(session, item) for item in body.items]

    # Reconfiguring a catalog role from the host wizard supersedes that same
    # host's older direct assignment instead of stacking two competing links.
    if body.target.type == "host" and body.target.id:
        plan_ids = [plan.id for plan, _version in resolved_items]
        old_targets = (await session.scalars(
            select(RoleDeploymentTarget)
            .join(RoleDeploymentItem, RoleDeploymentItem.id == RoleDeploymentTarget.item_id)
            .join(RoleDeployment, RoleDeployment.id == RoleDeploymentTarget.deployment_id)
            .where(
                RoleDeployment.scope_type == "host",
                RoleDeployment.agent_id == body.target.id,
                RoleDeploymentItem.plan_id.in_(plan_ids),
                RoleDeploymentTarget.state != "unmanaged",
            )
        )).all()
        for old in old_targets:
            if old.link_id:
                link = await session.get(OrchestrationPlanLink, old.link_id)
                if link is not None:
                    await session.delete(link)
                old.link_id = None
            old.state = "unmanaged"
            old.excluded = True
    deployment = RoleDeployment(
        id=uuid4(), tenant_id=TENANT, name=body.name.strip(), scope_type=body.target.type,
        status=status, require_approval=approval, pilot_enabled=p["pilot_enabled"],
        target_hash=p["target_hash"], removal_behavior="unmanage", created_by=identity.name,
        approved_by=None if approval else identity.name, **kw,
    )
    session.add(deployment)
    await session.flush()
    for index, (item_body, resolved) in enumerate(zip(body.items, resolved_items, strict=True)):
        plan, version = resolved
        session.add(RoleDeploymentItem(
            id=uuid4(), deployment_id=deployment.id, plan_id=plan.id,
            plan_version=version.version, parameters=item_body.parameters,
            item_order=index,
        ))
    await session.flush()
    await sync_targets(session, deployment)
    await session.commit()
    return await _detail(session, deployment)


async def _detail(session: AsyncSession, deployment: RoleDeployment) -> dict:
    items = (await session.scalars(select(RoleDeploymentItem).where(
        RoleDeploymentItem.deployment_id == deployment.id
    ).order_by(RoleDeploymentItem.item_order))).all()
    targets = (await session.scalars(select(RoleDeploymentTarget).where(
        RoleDeploymentTarget.deployment_id == deployment.id
    ))).all()
    plans = {p.id: p for p in (await session.scalars(select(OrchestrationPlan).where(
        OrchestrationPlan.id.in_([i.plan_id for i in items])
    ))).all()} if items else {}
    counts: dict[str, int] = {}
    for t in targets:
        counts[t.state] = counts.get(t.state, 0) + 1
    hosts = {a.id: a.name for a in (await session.scalars(select(Agent).where(
        Agent.id.in_({t.agent_id for t in targets})
    ))).all()} if targets else {}
    versions = {(v.plan_id, v.version): v for v in (await session.scalars(select(OrchestrationPlanVersion).where(
        OrchestrationPlanVersion.plan_id.in_([i.plan_id for i in items])
    ))).all()} if items else {}
    # Why a main-phase target has not been touched: the worker's own pilot gate, read back (one condition).
    wait = pilot_wait_reason(list(targets)) if deployment.status == "active" else None
    return {
        "id": str(deployment.id), "name": deployment.name, "status": deployment.status,
        "scope_type": deployment.scope_type, "agent_id": str(deployment.agent_id) if deployment.agent_id else None,
        "ou_id": str(deployment.ou_id) if deployment.ou_id else None,
        "host_group_id": str(deployment.host_group_id) if deployment.host_group_id else None,
        "site_id": str(deployment.site_id) if deployment.site_id else None,
        "require_approval": deployment.require_approval, "pilot_enabled": deployment.pilot_enabled,
        "created_by": deployment.created_by, "approved_by": deployment.approved_by,
        "created_at": deployment.created_at.isoformat() if deployment.created_at else None,
        "compliance": counts,
        "items": [{
            "id": str(i.id), "plan_id": str(i.plan_id), "name": plans[i.plan_id].name,
            "display_name": plans[i.plan_id].display_name, "kind": plans[i.plan_id].plan_type,
            "version": i.plan_version, "parameters": i.parameters,
            # Uninstall exists only for catalog-backed items (a package / Windows feature the catalog names);
            # an authored role has no inverse. Said here so the UI can refuse BEFORE the click, with the reason.
            "uninstall_blocked": None if ((versions.get((i.plan_id, i.plan_version)) and
                                           (versions[(i.plan_id, i.plan_version)].requirements or {}).get("catalog_name")))
            else f"{plans[i.plan_id].display_name} is not a catalog role — Bossman knows no uninstall for it; "
                 "Stop managing leaves it installed",
        } for i in items],
        "targets": [{
            "id": str(t.id), "item_id": str(t.item_id), "agent_id": str(t.agent_id),
            "host": hosts.get(t.agent_id),
            "waiting_for": wait if (wait and t.phase == "main" and t.state == "pending") else None,
            "phase": t.phase, "state": t.state, "last_error": t.last_error,
            "excluded": t.excluded,
            "detected_at": t.detected_at.isoformat() if t.detected_at else None,
            "applied_at": t.applied_at.isoformat() if t.applied_at else None,
        } for t in targets],
    }


@router.get("/api/v1/role-deployments")
async def list_deployments(session: AsyncSession = Depends(get_session),
                           identity: Identity = Depends(get_current_identity)) -> dict:
    rows = (await session.scalars(select(RoleDeployment).where(
        RoleDeployment.tenant_id == TENANT
    ).order_by(RoleDeployment.created_at.desc()))).all()
    visible = []
    for row in rows:
        try:
            await _ensure_manage_deployment(session, identity, row.id)
        except HTTPException:
            continue
        visible.append(await _detail(session, row))
    return {"deployments": visible}


@router.get("/api/v1/role-deployments/{deployment_id}")
async def get_deployment(deployment_id: UUID, session: AsyncSession = Depends(get_session),
                         identity: Identity = Depends(get_current_identity)) -> dict:
    row = await session.get(RoleDeployment, deployment_id)
    if row is None:
        raise HTTPException(404, "no such role deployment")
    await _ensure_manage_deployment(session, identity, deployment_id)
    return await _detail(session, row)


@router.post("/api/v1/role-deployments/{deployment_id}/approve")
async def approve(deployment_id: UUID, session: AsyncSession = Depends(get_session),
                  identity: Identity = Depends(get_current_identity)) -> dict:
    row = await session.scalar(select(RoleDeployment).where(
        RoleDeployment.id == deployment_id
    ).with_for_update())
    if row is None:
        raise HTTPException(404, "no such role deployment")
    if identity.kind != "user" or identity.role != "admin":
        raise HTTPException(403, "an administrator must approve this deployment")
    if row.status != "pending_approval":
        raise HTTPException(409, f"deployment is {row.status}, not pending approval")
    if row.created_by == identity.name:
        raise HTTPException(409, "four-eyes approval must come from a different administrator")
    row.status = "active"
    row.approved_by = identity.name
    await session.commit()
    return await _detail(session, row)


@router.post("/api/v1/role-deployments/{deployment_id}/reconcile")
async def reconcile_now(deployment_id: UUID, session: AsyncSession = Depends(get_session),
                        settings: Settings = Depends(get_settings),
                        identity: Identity = Depends(get_current_identity)) -> dict:
    row = await session.scalar(select(RoleDeployment).where(
        RoleDeployment.id == deployment_id
    ).with_for_update())
    if row is None:
        raise HTTPException(404, "no such role deployment")
    await _ensure_manage_deployment(session, identity, deployment_id)
    if row.status != "active":
        raise HTTPException(409, f"deployment is {row.status}, not active")
    await process_deployment_once(session, settings, deployment_id)
    await session.refresh(row)
    return await _detail(session, row)


@router.post("/api/v1/role-deployments/{deployment_id}/remediate")
async def remediate(deployment_id: UUID, body: RemediateIn, session: AsyncSession = Depends(get_session),
                    identity: Identity = Depends(get_current_identity)) -> dict:
    row = await session.get(RoleDeployment, deployment_id)
    if row is None:
        raise HTTPException(404, "no such role deployment")
    await _ensure_manage_deployment(session, identity, deployment_id)
    stmt = select(RoleDeploymentTarget).where(
        RoleDeploymentTarget.deployment_id == deployment_id,
        RoleDeploymentTarget.state.in_(("noncompliant", "error", "blocked")),
    )
    if body.target_ids:
        stmt = stmt.where(RoleDeploymentTarget.id.in_(body.target_ids))
    targets = (await session.scalars(stmt)).all()
    for target in targets:
        target.correction_requested = True
    await session.commit()
    return {"requested": len(targets)}


@router.post("/api/v1/role-deployments/{deployment_id}/retire")
async def retire(deployment_id: UUID, body: RetireIn, session: AsyncSession = Depends(get_session),
                 settings: Settings = Depends(get_settings),
                 client_factory=Depends(get_client_factory),
                 identity: Identity = Depends(get_current_identity)) -> dict:
    if body.behavior not in ("unmanage", "uninstall"):
        raise HTTPException(422, "behavior must be unmanage|uninstall")
    row = await session.scalar(select(RoleDeployment).where(
        RoleDeployment.id == deployment_id
    ).with_for_update())
    if row is None:
        raise HTTPException(404, "no such role deployment")
    await _ensure_manage_deployment(session, identity, deployment_id)
    targets = (await session.scalars(select(RoleDeploymentTarget).where(
        RoleDeploymentTarget.deployment_id == deployment_id
    ))).all()
    if body.behavior == "uninstall":
        actions = [await _uninstall_action(session, target, settings)
                   for target in targets if target.state != "unmanaged"]
        for agent, tool, params in actions:
            try:
                await client_factory(agent, settings).call_tool(tool, params)
            except Exception as exc:  # noqa: BLE001
                raise HTTPException(502, f"uninstall failed on {agent.name}: {exc}") from exc
    affected: set[UUID] = set()
    for target in targets:
        if target.link_id:
            link = await session.get(OrchestrationPlanLink, target.link_id)
            if link is not None:
                await session.delete(link)
            target.link_id = None
        target.state = "unmanaged"
        target.excluded = True
        affected.add(target.agent_id)
    row.status = "retired"
    row.removal_behavior = body.behavior
    await session.flush()
    for agent_id in affected:
        await compile_host_desired_state(session, agent_id)
    await session.commit()
    return await _detail(session, row)


@router.post("/api/v1/role-deployments/{deployment_id}/targets/{target_id}/remove")
async def remove_target(
    deployment_id: UUID,
    target_id: UUID,
    body: RetireIn,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    client_factory=Depends(get_client_factory),
    identity: Identity = Depends(get_current_identity),
) -> dict:
    """Stop managing one role/feature on one host, optionally uninstall it.

    Uninstall is deliberately explicit and catalog-backed.  Config files are
    not deleted implicitly; package-manager policy decides whether to retain
    them, and the deployment simply stops enforcing them.
    """
    if body.behavior not in ("unmanage", "uninstall"):
        raise HTTPException(422, "behavior must be unmanage|uninstall")
    # Serialize with the convergence worker, which holds the same deployment
    # row while applying.  Removing a link during an install must not be
    # followed by that install recreating it.
    deployment = await session.scalar(select(RoleDeployment).where(
        RoleDeployment.id == deployment_id
    ).with_for_update())
    if deployment is None:
        raise HTTPException(404, "no such role deployment")
    target = await session.scalar(select(RoleDeploymentTarget).where(
        RoleDeploymentTarget.id == target_id
    ).with_for_update())
    if target is None or target.deployment_id != deployment_id:
        raise HTTPException(404, "no such deployment target")
    if not await user_can_manage_agent(session, identity, target.agent_id):
        raise HTTPException(403, "not authorized to manage this host")
    if body.behavior == "uninstall":
        agent, tool, params = await _uninstall_action(session, target, settings)
        try:
            await client_factory(agent, settings).call_tool(tool, params)
        except Exception as exc:  # noqa: BLE001
            raise HTTPException(502, f"uninstall failed: {exc}") from exc
    if target.link_id:
        link = await session.get(OrchestrationPlanLink, target.link_id)
        if link is not None:
            await session.delete(link)
        target.link_id = None
    target.state = "unmanaged"
    target.excluded = True
    target.last_error = None
    await session.flush()
    await compile_host_desired_state(session, target.agent_id)
    await session.commit()
    return {"ok": True, "behavior": body.behavior, "target_id": str(target.id)}
