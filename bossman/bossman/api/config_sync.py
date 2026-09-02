"""Config-distribution sync API (gap #15): visibility into the convergence
sweep + an on-demand "sync now". The sweep also runs automatically on an
interval; this just lets an operator see its state and force a pass.
"""

from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity, require_admin
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent, AgentConfigDelivery, CompiledHostState
from bossman.db.session import get_session
from bossman.services import reconciler

router = APIRouter()


class SyncStatus(BaseModel):
    enabled: bool
    interval_seconds: int
    last_run_at: datetime | None
    checked: int
    pushed: int
    failed: int
    hosts_behind: int  # compiled generation ahead of last ack (drift)


class SyncRunResult(BaseModel):
    checked: int
    pushed: int
    failed: int


async def _hosts_behind(session: AsyncSession) -> int:
    """How many agents have a compiled generation newer than their newest acked
    delivery — i.e. are carrying stale config right now."""
    acked = (
        select(AgentConfigDelivery.agent_id, func.max(AgentConfigDelivery.generation).label("g"))
        .where(AgentConfigDelivery.status == "acked")
        .group_by(AgentConfigDelivery.agent_id)
        .subquery()
    )
    rows = (await session.execute(
        select(CompiledHostState.agent_id, CompiledHostState.generation, acked.c.g)
        .outerjoin(acked, acked.c.agent_id == CompiledHostState.agent_id)
    )).all()
    return sum(1 for _aid, gen, ack in rows if gen > (ack or 0))


@router.get("/api/v1/config-sync/status", response_model=SyncStatus)
async def status(
    request: Request,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _i: Identity = Depends(get_current_identity),
):
    """Which hosts are behind on their desired state, and by how much.

    Compares each host's compiled generation against what it last **acked**. A host ahead of its ack
    has a change waiting; one that never acked has never received anything. Two different states, both
    named rather than shown as an empty row.
    """
    st = getattr(request.app.state, "converge_stats", None)
    return SyncStatus(
        enabled=settings.config_sync_enabled,
        interval_seconds=settings.config_sync_interval_seconds,
        last_run_at=getattr(st, "last_run_at", None),
        checked=getattr(st, "checked", 0),
        pushed=getattr(st, "pushed", 0),
        failed=getattr(st, "failed", 0),
        hosts_behind=await _hosts_behind(session),
    )


@router.post("/api/v1/config-sync/run", response_model=SyncRunResult)
async def run_now(
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    client_factory=Depends(get_client_factory),
    _admin: Identity = Depends(require_admin),
):
    """Force the convergence sweep now instead of waiting for the cycle.

    Recompiles every host's desired state and pushes to any whose generation is ahead of its ack —
    which is also how a change made through an endpoint that enqueues no event reaches the hosts (a
    policy site's subnets, for instance). Idempotent: an up-to-date, acked host is skipped.
    """
    run = await reconciler.converge_once(session, settings, client_factory=client_factory)
    return SyncRunResult(checked=run.checked, pushed=run.pushed, failed=run.failed)
