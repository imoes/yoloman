"""Staged rollout API (gap #8): create a wave plan (canary/rings) from a scope,
start it, watch live per-wave progress with a health gate.
"""

from __future__ import annotations

import asyncio
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.api.agents import get_session_factory
from bossman.api.auth import Identity, get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Rollout
from bossman.db.session import get_session
from bossman.services.compiler import affected_agent_ids
from bossman.services.rollout import execute_rollout, plan_waves, plan_waves_by_ou

router = APIRouter()
DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


class RolloutIn(BaseModel):
    name: str
    runbook_name: str
    # Optional post-upgrade functional test (an Ansible-style runbook, AI-authorable):
    # each wave passes the gate only if this test succeeds on its hosts.
    test_runbook_name: str | None = None
    # One host per wave (blast radius 1): upgrade + test one machine, gate, then
    # the next — the safest cadence for a dist-upgrade on a test group.
    one_at_a_time: bool = False
    scope_type: str  # host | group | ou | global
    agent_id: UUID | None = None
    host_group_id: UUID | None = None
    ou_id: UUID | None = None
    strategy: list = [1, "25%", "rest"]  # canary, quarter, rest
    # AD-consistent waves: one wave per OU in the target subtree (shallow→deep),
    # instead of percentage slices of a flat host list. Requires scope_type=ou.
    by_ou: bool = False
    canary: bool = True  # (by_ou) pull the first host into a leading canary wave
    variables: dict = {}
    dry_run: bool = False
    wait_seconds: int = 30
    max_fail_pct: float = 0.0  # abort if >0% of a wave goes hard-CRIT


class RolloutOut(BaseModel):
    id: UUID
    name: str
    runbook_name: str
    test_runbook_name: str | None = None
    dry_run: bool
    status: str
    current_wave: int
    waves: list
    health_gate: dict
    progress: list
    started_at: datetime | None
    finished_at: datetime | None
    created_at: datetime

    @classmethod
    def of(cls, r: Rollout) -> "RolloutOut":
        return cls(
            id=r.id, name=r.name, runbook_name=r.runbook_name, test_runbook_name=r.test_runbook_name,
            dry_run=r.dry_run, status=r.status,
            current_wave=r.current_wave, waves=r.waves or [], health_gate=r.health_gate or {},
            progress=r.progress or [], started_at=r.started_at, finished_at=r.finished_at, created_at=r.created_at,
        )


@router.get("/api/v1/rollouts", response_model=list[RolloutOut])
async def list_rollouts(session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    rows = (await session.scalars(select(Rollout).order_by(Rollout.created_at.desc()))).all()
    return [RolloutOut.of(r) for r in rows]


@router.get("/api/v1/rollouts/{rollout_id}", response_model=RolloutOut)
async def get_rollout(rollout_id: UUID, session: AsyncSession = Depends(get_session),
                      _i: Identity = Depends(get_current_identity)):
    r = await session.get(Rollout, rollout_id)
    if r is None:
        raise HTTPException(404, "no such rollout")
    return RolloutOut.of(r)


@router.post("/api/v1/rollouts", response_model=RolloutOut)
async def create_rollout(body: RolloutIn, session: AsyncSession = Depends(get_session),
                         identity: Identity = Depends(get_current_identity)):
    if body.scope_type not in ("host", "group", "ou", "global"):
        raise HTTPException(422, "scope_type must be host|group|ou|global")
    if body.by_ou:
        # AD-consistent: waves follow the OU subtree (one wave per OU).
        if body.scope_type != "ou" or body.ou_id is None:
            raise HTTPException(422, "by_ou requires scope_type=ou and ou_id")
        waves = await plan_waves_by_ou(session, body.ou_id, canary=body.canary)
        if not waves:
            raise HTTPException(422, "OU subtree has no placed, reachable hosts")
    else:
        agent_ids = await affected_agent_ids(
            session, body.scope_type, ou_id=body.ou_id, agent_id=body.agent_id,
            host_group_id=body.host_group_id, tenant_id=DEFAULT_TENANT_ID,
        )
        if not agent_ids:
            raise HTTPException(422, "scope matched no hosts")
        waves = plan_waves([str(a) for a in agent_ids], body.strategy)
    if body.one_at_a_time:
        # Explode into one host per wave, preserving order (by_ou/strategy order),
        # so a bad upgrade stops after a single machine.
        exploded: list = []
        for w in waves:
            for aid in w["agent_ids"]:
                exploded.append({"name": f"{w['name']} · {aid[:8]}", "agent_ids": [aid]})
        waves = exploded or waves
    r = Rollout(
        tenant_id=DEFAULT_TENANT_ID, name=body.name, runbook_name=body.runbook_name,
        test_runbook_name=body.test_runbook_name or None,
        variables=body.variables, dry_run=body.dry_run, waves=waves,
        health_gate={"wait_seconds": body.wait_seconds, "max_fail_pct": body.max_fail_pct},
        status="pending", created_by=identity.name,
    )
    session.add(r)
    await session.commit()
    await session.refresh(r)
    return RolloutOut.of(r)


@router.post("/api/v1/rollouts/{rollout_id}/start", response_model=RolloutOut)
async def start_rollout(rollout_id: UUID, session: AsyncSession = Depends(get_session),
                        settings: Settings = Depends(get_settings),
                        session_factory: async_sessionmaker[AsyncSession] = Depends(get_session_factory),
                        client_factory=Depends(get_client_factory), _i: Identity = Depends(get_current_identity)):
    r = await session.get(Rollout, rollout_id)
    if r is None:
        raise HTTPException(404, "no such rollout")
    if r.status == "running":
        raise HTTPException(409, "rollout already running")
    # Fire-and-forget background driver; progress is polled via GET.
    asyncio.create_task(execute_rollout(session_factory, settings, rollout_id, client_factory))
    r.status = "running"
    await session.commit()
    await session.refresh(r)
    return RolloutOut.of(r)


@router.post("/api/v1/rollouts/{rollout_id}/abort", response_model=RolloutOut)
async def abort_rollout(rollout_id: UUID, session: AsyncSession = Depends(get_session),
                        _i: Identity = Depends(get_current_identity)):
    r = await session.get(Rollout, rollout_id)
    if r is None:
        raise HTTPException(404, "no such rollout")
    if r.status in ("running", "pending", "paused"):
        r.status = "aborted"
        await session.commit()
        await session.refresh(r)
    return RolloutOut.of(r)


@router.delete("/api/v1/rollouts/{rollout_id}", status_code=204)
async def delete_rollout(rollout_id: UUID, session: AsyncSession = Depends(get_session),
                         _i: Identity = Depends(get_current_identity)):
    r = await session.get(Rollout, rollout_id)
    if r is not None:
        await session.delete(r)
        await session.commit()
