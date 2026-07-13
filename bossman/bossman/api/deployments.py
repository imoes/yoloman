"""Multi-host deployments: fan a plan or runbook out across a resolved target
set (agents / free-text hostnames / groups / OU subtrees / tags) in one action,
tracking the per-host child runs as a single DeploymentRun aggregate.

This is the server-side counterpart to what previously only existed as a
client-side loop in the AI chat task — every prior run endpoint was one-host.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import DEFAULT_TENANT_ID, Agent, DeploymentRun
from bossman.db.session import get_session
from bossman.services import nt_runbook
from bossman.services.auth import Identity, user_can_manage_agent
from bossman.services.plan_engine import run_plan
from bossman.services.plan_loader import PlanError, load_host_vars
from bossman.services.plan_store import load_plan as store_load_plan
from bossman.services.runbook_exec import execute_runbook
from bossman.services.targets import TargetSpec, resolve_targets

router = APIRouter()


class DeploymentTargets(BaseModel):
    agent_ids: list[UUID] = []
    hostnames: list[str] = []  # free-text list, matched by agent name
    group_ids: list[UUID] = []
    ou_ids: list[UUID] = []
    tags: dict[str, str | None] = {}


class DeploymentRunRequest(BaseModel):
    kind: str  # 'stored_plan' | 'runbook'
    # stored_plan:
    prefix: str | None = None
    name: str | None = None
    # runbook (NestedText source, like POST /agents/{id}/runbook/run):
    runbook_nt: str | None = None
    runbook_name: str | None = None
    params: dict[str, Any] = {}
    dry_run: bool = True
    targets: DeploymentTargets = DeploymentTargets()


_OK = {"succeeded", "ok"}


@router.post("/api/v1/deployments/run")
async def run_deployment(
    body: DeploymentRunRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity: Identity = Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Resolve the target set, run the plan/runbook against each host, and
    persist one DeploymentRun grouping the per-host child runs."""
    if body.kind not in ("stored_plan", "runbook"):
        raise HTTPException(status_code=422, detail="kind must be stored_plan|runbook")

    # Validate the artifact up front (fail fast before touching hosts).
    doc = None
    if body.kind == "stored_plan":
        if not body.prefix or not body.name:
            raise HTTPException(status_code=422, detail="stored_plan needs prefix + name")
        target_ref = f"{body.prefix}/{body.name}"
    else:
        if not body.runbook_nt:
            raise HTTPException(status_code=422, detail="runbook needs runbook_nt (NestedText source)")
        try:
            doc = nt_runbook.parse_document(body.runbook_nt)
        except nt_runbook.NTRunbookError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        if not isinstance(doc, nt_runbook.Runbook):
            raise HTTPException(status_code=422, detail="that is a role, not a runbook — bind it in OU / Policy instead")
        target_ref = body.runbook_name or doc.name

    spec = TargetSpec(
        agent_ids=body.targets.agent_ids, hostnames=body.targets.hostnames,
        group_ids=body.targets.group_ids, ou_ids=body.targets.ou_ids, tags=body.targets.tags,
    )
    resolution = await resolve_targets(session, DEFAULT_TENANT_ID, spec)
    if not resolution.agents and not resolution.unknown_hostnames:
        raise HTTPException(status_code=422, detail="no targets resolved from the given selectors")

    results: list[dict[str, Any]] = []
    for agent in resolution.agents:
        entry: dict[str, Any] = {"agent_id": str(agent.id), "agent_name": agent.name}
        if not await user_can_manage_agent(session, identity, agent.id):
            results.append({**entry, "status": "forbidden", "error": "not authorized to manage this host"})
            continue
        if not agent.address:
            results.append({**entry, "status": "failed", "error": "agent has no reachable address"})
            continue
        client = client_factory(agent, settings)
        try:
            if body.kind == "stored_plan":
                plan = await store_load_plan(session, body.prefix, body.name)
                host_vars = load_host_vars(settings.plans_dir, agent.name)
                run = await run_plan(
                    session, agent, plan, host_vars=host_vars, explicit_params=body.params,
                    dry_run=body.dry_run, client=client, requested_by=identity.name,
                )
                results.append({**entry, "run_kind": "plan", "run_id": str(run.id), "status": run.status})
            else:
                rr, _ = await execute_runbook(
                    session, agent, doc, settings=settings, client=client,
                    request_vars=body.params, dry_run=body.dry_run, requested_by=identity.name,
                )
                results.append({**entry, "run_kind": "runbook", "run_id": str(rr.id),
                                "status": rr.status, "changed": rr.changed})
        except PlanError as exc:
            results.append({**entry, "status": "failed", "error": str(exc)})
        except Exception as exc:  # noqa: BLE001 — one host's failure must not sink the whole deployment
            results.append({**entry, "status": "failed", "error": str(exc)})

    ok = sum(1 for r in results if r.get("status") in _OK)
    failed = len(results) - ok
    if not results:
        status = "failed"
    elif failed == 0:
        status = "ok"
    elif ok == 0:
        status = "failed"
    else:
        status = "partial"

    dep = DeploymentRun(
        tenant_id=DEFAULT_TENANT_ID, kind=body.kind, target_ref=target_ref, dry_run=body.dry_run,
        status=status, total_hosts=len(results), ok_hosts=ok, failed_hosts=failed,
        unknown_hostnames=resolution.unknown_hostnames, results=results, requested_by=identity.name,
    )
    session.add(dep)
    await session.commit()
    return _serialize(dep)


@router.get("/api/v1/deployments")
async def list_deployments(
    limit: int = 50, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """The multi-host deployment audit trail, newest first."""
    rows = (
        await session.scalars(
            select(DeploymentRun).where(DeploymentRun.tenant_id == DEFAULT_TENANT_ID)
            .order_by(DeploymentRun.created_at.desc()).limit(limit)
        )
    ).all()
    return {"deployments": [_serialize(d, brief=True) for d in rows]}


@router.get("/api/v1/deployments/{deployment_id}")
async def get_deployment(
    deployment_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    dep = await session.get(DeploymentRun, deployment_id)
    if dep is None:
        raise HTTPException(status_code=404, detail="no such deployment")
    return _serialize(dep)


def _serialize(d: DeploymentRun, *, brief: bool = False) -> dict[str, Any]:
    out = {
        "id": str(d.id), "kind": d.kind, "target_ref": d.target_ref, "dry_run": d.dry_run,
        "status": d.status, "total_hosts": d.total_hosts, "ok_hosts": d.ok_hosts,
        "failed_hosts": d.failed_hosts, "unknown_hostnames": d.unknown_hostnames,
        "requested_by": d.requested_by, "created_at": d.created_at.isoformat() if d.created_at else None,
    }
    if not brief:
        out["results"] = d.results
    return out
