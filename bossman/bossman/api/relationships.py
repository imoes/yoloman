"""GET /api/v1/relationships — what this host talks to, GROUPED, with the raw edges available on request.

Served from `host_edges`, the view services/poller.py maintains from each agent's own
GET /api/v1/net/connections/dump.

WHY THIS IS NO LONGER A BARE DUMP. It returned every row, unordered by size and unbounded. Measured on one
host in this fleet:

    28 203 rows  →  5.46 MB  to the browser, on every host-page load
    …made of 40 process names, 10 destination addresses, and 14 158 DISTINCT dst_ports

kubelet (14 126 rows) and kube-apiserver (13 875) are 99.6% of it. The table's docstring called host_edges
"already-aggregated", and it is — per (src_comm, dst_addr, dst_port). That grouping is simply wrong for this
traffic: those ~14 000 ports are ephemeral, so every short-lived connection becomes its own permanent
"relationship" row. The FACT an operator wants is "kubelet talks to 10.x.y.z" — one line, not 14 126.

So the default answer groups by (src_comm, dst_addr) and says how many ports and edges it stands for. 5.46 MB
becomes a few KB, and the Relationships table becomes readable: nobody reads 28 203 rows, which is why the
size was never noticed as a defect — the page "worked".

NOTHING IS HIDDEN. `total_edges` and `truncated` travel with the reply, and `raw=true` returns the
underlying edges (busiest first, capped, with the same total) for the case that genuinely wants connections.
A silent top-N would make a partial answer look complete.

v1 scope is still direct edges only (depth=1). A recursive multi-hop query remains available and unbuilt
until a real use case shows up.
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import desc, func, select
from sqlalchemy.dialects.postgresql import aggregate_order_by
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import HostEdge
from bossman.db.session import get_session

router = APIRouter()

#: Default cap. Generous enough that a normal host is never truncated (a host with no ephemeral-port churn
#: has tens of groups, not hundreds) and small enough that the pathological case stays a few KB.
DEFAULT_LIMIT = 200
MAX_LIMIT = 5000


class EdgeOut(BaseModel):
    """One raw edge — a (process, destination, port) the poller has seen."""

    src_agent_id: UUID
    src_comm: str
    dst_addr: str
    dst_port: int
    dst_agent_id: UUID | None
    event_count: int
    latency_ms_p50: float | None


class EdgeGroupOut(BaseModel):
    """One process talking to one destination, however many ports that took."""

    src_agent_id: UUID
    src_comm: str
    dst_addr: str
    #: The single port when there is exactly one — the common, readable case. None when there are several,
    #: because naming one of 14 158 would be picking an arbitrary example and calling it the answer.
    dst_port: int | None
    ports: int
    dst_agent_id: UUID | None
    event_count: int
    #: The p50 OF THE BUSIEST EDGE in the group, and named for that rather than for the group.
    #:
    #: There is no honest "p50 of a group of medians". max() was the first attempt and it was measured to be
    #: nonsense: over kubelet's 14 119 ephemeral-port rows the maximum p50 is 57 804 453 ms — 16 hours — one
    #: dead connection's timeout presented as the group's latency. An average of medians is not a median
    #: either. So this is one real measurement of one real connection: the one carrying the most events.
    latency_ms_p50_busiest: float | None
    edges: int


class RelationshipsOut(BaseModel):
    groups: list[EdgeGroupOut]
    #: Present only when raw=true was asked for.
    edges: list[EdgeOut] | None = None
    #: Every edge row that matched, before any cap — so a truncated answer can say what it is part of.
    total_edges: int
    total_groups: int
    truncated: bool


@router.get("/api/v1/relationships", response_model=RelationshipsOut)
async def list_relationships(
    agent_id: UUID | None = Query(None, description="Limit to edges originating from this agent"),
    raw: bool = Query(False, description="Also return the underlying edges, busiest first"),
    limit: int = Query(DEFAULT_LIMIT, ge=1, le=MAX_LIMIT, description="Max groups (and raw edges) returned"),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> RelationshipsOut:
    where = [HostEdge.src_agent_id == agent_id] if agent_id is not None else []

    # GROUPED IN THE DATABASE, not in Python: the point is to not transfer 28 203 rows, and loading them
    # here to fold them would keep the cost and only hide it from the browser.
    grouped = (
        select(
            HostEdge.src_agent_id,
            HostEdge.src_comm,
            HostEdge.dst_addr,
            func.count().label("edges"),
            func.count(func.distinct(HostEdge.dst_port)).label("ports"),
            func.min(HostEdge.dst_port).label("one_port"),
            func.sum(HostEdge.event_count).label("event_count"),
            # The busiest edge's p50 — see EdgeGroupOut.latency_ms_p50_busiest for why not max() or an
            # average. array_agg with an ORDER BY inside the aggregate is the plain-SQL way to say
            # "the value belonging to the largest event_count".
            (func.array_agg(aggregate_order_by(
                HostEdge.latency_ms_p50, HostEdge.event_count.desc()))[1]).label("latency_busiest"),
            # GROUPED BY, not aggregated. dst_agent_id is a function of dst_addr (the poller resolves the
            # address to an enrolled agent), so grouping by it yields the same groups — and if it ever is
            # not, splitting them is the more correct answer, not a lost distinction. Postgres also has no
            # max(uuid), which is how this came up: the aggregate was a habit, not a requirement.
            HostEdge.dst_agent_id,
        )
        .where(*where)
        .group_by(HostEdge.src_agent_id, HostEdge.src_comm, HostEdge.dst_addr, HostEdge.dst_agent_id)
        # Busiest first, so a cap keeps what matters instead of whatever the table happened to order by.
        .order_by(desc("event_count"))
    )
    rows = (await session.execute(grouped.limit(limit))).all()

    # The TOTALS, counted separately from the capped page: a reply that says "200 groups" without saying
    # "of 1042" is a partial answer wearing the clothes of a complete one. order_by(None) drops the ORDER BY
    # before the subquery — Postgres does not need it to count and some versions reject it there.
    total_groups = await session.scalar(
        select(func.count()).select_from(grouped.order_by(None).subquery())) or 0
    total_edges = await session.scalar(
        select(func.count()).select_from(HostEdge).where(*where)) or 0

    groups = [
        EdgeGroupOut(
            src_agent_id=r.src_agent_id,
            src_comm=r.src_comm,
            dst_addr=str(r.dst_addr),
            dst_port=int(r.one_port) if r.ports == 1 else None,
            ports=int(r.ports),
            dst_agent_id=r.dst_agent_id,
            event_count=int(r.event_count or 0),
            latency_ms_p50_busiest=r.latency_busiest,
            edges=int(r.edges),
        )
        for r in rows
    ]

    edges: list[EdgeOut] | None = None
    if raw:
        stmt = (select(HostEdge).where(*where)
                .order_by(HostEdge.event_count.desc(), HostEdge.last_seen_at.desc())
                .limit(limit))
        edges = [
            EdgeOut(
                src_agent_id=e.src_agent_id, src_comm=e.src_comm, dst_addr=str(e.dst_addr),
                dst_port=e.dst_port, dst_agent_id=e.dst_agent_id, event_count=e.event_count,
                latency_ms_p50=e.latency_ms_p50,
            )
            for e in (await session.scalars(stmt)).all()
        ]

    return RelationshipsOut(
        groups=groups,
        edges=edges,
        total_edges=int(total_edges),
        total_groups=int(total_groups),
        truncated=total_groups > len(groups) or bool(raw and total_edges > len(edges or [])),
    )
