"""GET /api/v1/relationships — the host-relationship graph (see
docs/plan.md's Bossman plan, section B.7 and the eBPF-persistence design
in "Bossman — Block A" above): served straight from host_edges, the
already-aggregated view services/poller.py maintains from each agent's
own GET /api/v1/net/connections/dump.

v1 scope: direct edges only (depth=1, i.e. "what does this agent talk
to"), matching the plan's own note that a relational edges table is
sufficient at this fleet's scale and that a recursive multi-hop query
(`WITH RECURSIVE`) is an available, not yet needed, extension — added
later if a real multi-hop use case shows up rather than built speculatively
now.
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import HostEdge
from bossman.db.session import get_session

router = APIRouter()


class EdgeOut(BaseModel):
    src_agent_id: UUID
    src_comm: str
    dst_addr: str
    dst_port: int
    dst_agent_id: UUID | None
    event_count: int
    latency_ms_p50: float | None


@router.get("/api/v1/relationships", response_model=list[EdgeOut])
async def list_relationships(
    agent_id: UUID | None = Query(None, description="Limit to edges originating from this agent"),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[EdgeOut]:
    stmt = select(HostEdge)
    if agent_id is not None:
        stmt = stmt.where(HostEdge.src_agent_id == agent_id)
    stmt = stmt.order_by(HostEdge.last_seen_at.desc())
    edges = (await session.scalars(stmt)).all()
    return [
        EdgeOut(
            src_agent_id=e.src_agent_id,
            src_comm=e.src_comm,
            dst_addr=str(e.dst_addr),
            dst_port=e.dst_port,
            dst_agent_id=e.dst_agent_id,
            event_count=e.event_count,
            latency_ms_p50=e.latency_ms_p50,
        )
        for e in edges
    ]
