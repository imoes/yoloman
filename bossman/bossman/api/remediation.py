"""Remediation policies API — bind a parameter-driven remediation runbook to a
check, and trigger/audit remediations. See services/remediation.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import DEFAULT_TENANT_ID, Agent, RemediationPolicy, RemediationRun
from bossman.db.session import get_session

router = APIRouter()


class RemediationPolicyIn(BaseModel):
    name: str
    match_service_name: str = ""  # "" = any check
    scope_type: str = "global"    # global|ou|group|host
    ou_id: UUID | None = None
    host_group_id: UUID | None = None
    agent_id: UUID | None = None
    conditions: dict = {}
    runbook_name: str
    params: dict = {}
    max_per_hour: int = 3
    mode: str = "auto"            # auto | propose
    enabled: bool = True


class RemediationPolicyOut(BaseModel):
    id: UUID
    name: str
    match_service_name: str
    scope_type: str
    ou_id: UUID | None
    host_group_id: UUID | None
    agent_id: UUID | None
    conditions: dict
    runbook_name: str
    params: dict
    max_per_hour: int
    mode: str
    enabled: bool

    @classmethod
    def of(cls, p: RemediationPolicy) -> "RemediationPolicyOut":
        return cls(
            id=p.id, name=p.name, match_service_name=p.match_service_name, scope_type=p.scope_type,
            ou_id=p.ou_id, host_group_id=p.host_group_id, agent_id=p.agent_id, conditions=p.conditions or {},
            runbook_name=p.runbook_name, params=p.params or {}, max_per_hour=p.max_per_hour,
            mode=p.mode, enabled=p.enabled,
        )


@router.get("/api/v1/remediation-policies", response_model=list[RemediationPolicyOut])
async def list_remediation_policies(session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    rows = (await session.scalars(select(RemediationPolicy).order_by(RemediationPolicy.created_at.desc()))).all()
    return [RemediationPolicyOut.of(p) for p in rows]


@router.post("/api/v1/remediation-policies", response_model=RemediationPolicyOut)
async def create_remediation_policy(
    body: RemediationPolicyIn, session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
):
    if body.scope_type not in ("global", "ou", "group", "host"):
        raise HTTPException(422, "scope_type must be global|ou|group|host")
    if body.mode not in ("auto", "propose"):
        raise HTTPException(422, "mode must be auto|propose")
    p = RemediationPolicy(
        tenant_id=DEFAULT_TENANT_ID, name=body.name, match_service_name=body.match_service_name,
        scope_type=body.scope_type, ou_id=body.ou_id, host_group_id=body.host_group_id, agent_id=body.agent_id,
        conditions=body.conditions or {}, runbook_name=body.runbook_name, params=body.params or {},
        max_per_hour=body.max_per_hour, mode=body.mode, enabled=body.enabled, created_by=identity.name,
    )
    session.add(p)
    await session.commit()
    await session.refresh(p)
    return RemediationPolicyOut.of(p)


@router.delete("/api/v1/remediation-policies/{policy_id}", status_code=204)
async def delete_remediation_policy(policy_id: UUID, session: AsyncSession = Depends(get_session),
                                    _i: Identity = Depends(get_current_identity)):
    p = await session.get(RemediationPolicy, policy_id)
    if p is not None:
        await session.delete(p)
        await session.commit()


class RemediationRunOut(BaseModel):
    id: UUID
    policy_id: UUID | None
    agent_id: UUID | None
    service_name: str
    runbook_name: str
    status: str
    detail: str | None
    at: datetime
    # closed-loop lifecycle
    phase: str
    applied_at: datetime | None
    verified_at: datetime | None
    verify_state: str | None
    verify_ok: bool | None
    outcome: str | None


@router.get("/api/v1/remediation-runs", response_model=list[RemediationRunOut])
async def list_remediation_runs(status: str | None = Query(None), limit: int = Query(100, ge=1, le=500),
                                session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    """Remediation history + the pending-proposal queue (?status=pending)."""
    stmt = select(RemediationRun)
    if status:
        stmt = stmt.where(RemediationRun.status == status)
    rows = (await session.scalars(stmt.order_by(RemediationRun.at.desc()).limit(limit))).all()
    return [RemediationRunOut(
        id=r.id, policy_id=r.policy_id, agent_id=r.agent_id, service_name=r.service_name,
        runbook_name=r.runbook_name, status=r.status, detail=r.detail, at=r.at,
        phase=r.phase, applied_at=r.applied_at, verified_at=r.verified_at,
        verify_state=r.verify_state, verify_ok=r.verify_ok, outcome=r.outcome,
    ) for r in rows]


@router.post("/api/v1/remediation-runs/{run_id}/apply")
async def apply_remediation_run(
    run_id: UUID, session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _i: Identity = Depends(get_current_identity), client_factory=Depends(get_client_factory),
) -> dict:
    """Apply a PENDING remediation proposal now — the manual "Apply" action.
    Self-healing never runs automatically; this is the only execution path
    (besides the direct /remediate trigger)."""
    run = await session.get(RemediationRun, run_id)
    if run is None:
        raise HTTPException(404, "no such remediation run")
    if run.status != "pending":
        raise HTTPException(409, f"run is '{run.status}', not pending")
    from bossman.services.remediation import apply_run

    result = await apply_run(session, settings, run, client_factory)
    await session.commit()
    return result


@router.post("/api/v1/remediation-runs/{run_id}/dismiss", status_code=204)
async def dismiss_remediation_run(run_id: UUID, session: AsyncSession = Depends(get_session),
                                  _i: Identity = Depends(get_current_identity)) -> None:
    """Dismiss a pending proposal without running it."""
    run = await session.get(RemediationRun, run_id)
    if run is not None and run.status == "pending":
        run.status = "dismissed"
        await session.commit()


@router.post("/api/v1/agents/{agent_id}/remediate")
async def trigger_remediation(
    agent_id: UUID, service: str = Query(...),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _i: Identity = Depends(get_current_identity), client_factory=Depends(get_client_factory),
) -> dict:
    """Manually run the remediation policies matching (host, check) now — bypasses
    the rate limit (an operator/AI-initiated heal)."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(404, "no such host")
    from bossman.services.remediation import run_remediations_for_service

    results = await run_remediations_for_service(session, settings, agent, service, client_factory, force=True)
    await session.commit()
    return {"host": agent.name, "service": service, "results": results}
