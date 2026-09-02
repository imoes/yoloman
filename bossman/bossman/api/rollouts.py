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
    """Every staged rollout, with its wave plan and its live per-wave progress.

    A rollout is one runbook applied to many hosts **in waves** — a canary first, then rings — with a
    health gate between them. `progress` grows one entry per completed wave and carries that wave's
    health verdict, so this is also the answer to "why did it stop".
    """
    rows = (await session.scalars(select(Rollout).order_by(Rollout.created_at.desc()))).all()
    return [RolloutOut.of(r) for r in rows]


@router.get("/api/v1/rollouts/{rollout_id}", response_model=RolloutOut)
async def get_rollout(rollout_id: UUID, session: AsyncSession = Depends(get_session),
                      _i: Identity = Depends(get_current_identity)):
    """One rollout: its waves, which wave is current, and each finished wave's health verdict.
    404 when there is no such id."""
    r = await session.get(Rollout, rollout_id)
    if r is None:
        raise HTTPException(404, "no such rollout")
    return RolloutOut.of(r)


@router.post("/api/v1/rollouts", response_model=RolloutOut)
async def create_rollout(body: RolloutIn, session: AsyncSession = Depends(get_session),
                         identity: Identity = Depends(get_current_identity)):
    """Plan the waves. **Nothing runs until `/start`.**

    The scope (host, group, ou, global) is expanded to hosts now and frozen into a wave plan, so a
    host added to the group afterwards is not silently pulled into a running rollout. `by_ou` builds
    one wave per OU subtree instead of by ring, and requires `scope_type=ou` with an `ou_id` (422).

    Two refusals worth expecting: **422 when the scope matched no hosts**, and 422 when an OU subtree
    has no placed, reachable hosts. A rollout over an empty set would report success having done
    nothing.
    """
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
    """Start the rollout. Returns immediately; the waves run server-side.

    **409 when it is already running** — starting twice would run two wave sequences over the same
    hosts. Follow it with `GET` on this rollout rather than expecting a result here.

    What happens per wave: run the runbook on the wave's hosts, wait `health_gate.wait_seconds` for
    state to settle, optionally run a functional test runbook, then gate. The gate compares against a
    **pre-wave baseline of CRIT hosts**, so only NEW damage counts — a host that was already broken
    does not block the rollout, and a wave that breaks something does. A failed gate sets the rollout
    `aborted` and the remaining waves do not run.
    """
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
    """Ask the rollout to stop. **It stops at the next wave boundary, not instantly.**

    This sets the status to `aborted`; the executor reads that status before each wave and returns
    when it sees it. A wave already in flight therefore **finishes** — its hosts are mid-runbook and
    killing that would leave them half-applied, which is worse than one more wave.

    Accepted while `running`, `pending` or `paused`, and a no-op otherwise: aborting a finished
    rollout changes nothing and is not an error worth raising.
    """
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
    """Delete a rollout and its recorded progress.

    **204 whether or not it existed.** Note what this does not do: it does not stop a running one —
    abort it first, or the executor keeps working through the waves of a plan nobody can watch any
    more.
    """
    r = await session.get(Rollout, rollout_id)
    if r is not None:
        await session.delete(r)
        await session.commit()
