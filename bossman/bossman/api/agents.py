"""GET /api/v1/agents, /api/v1/agents/{id}, and /api/v1/agents/{id}/metrics
— the fleet inventory + per-agent metric history views (see docs/plan.md's
Bossman plan, section B.7). These serve Bossman's own already-aggregated
Postgres data (see services/poller.py) — never a live pull from the agent
itself, which is exactly the point of polling ahead of time.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import Agent, Metric
from bossman.db.session import get_session

router = APIRouter()


class AgentOut(BaseModel):
    id: UUID
    name: str
    address: str | None
    mode: str
    enrollment_state: str
    last_seen_at: datetime | None
    metadata: dict
    groups: list[str]
    parent_agent_id: UUID | None
    # The host's HW/SW inventory document (Block H2) + when it last changed.
    facts: dict
    facts_updated_at: datetime | None

    @classmethod
    def from_model(cls, agent: Agent) -> "AgentOut":
        return cls(
            id=agent.id,
            name=agent.name,
            address=agent.address,
            mode=agent.mode,
            enrollment_state=agent.enrollment_state,
            last_seen_at=agent.last_seen_at,
            metadata=agent.agent_metadata,
            groups=agent.groups,
            parent_agent_id=agent.parent_agent_id,
            facts=agent.facts or {},
            facts_updated_at=agent.facts_updated_at,
        )


class MetricPointOut(BaseModel):
    time: datetime
    value: float
    labels: dict


class LatestMetricOut(BaseModel):
    """One metric's most recent sample — the "Last value / Last check" row of
    a Zabbix-style latest-data list (see the host-detail Metrics tab). One
    row per metric *name*; multi-series metrics (e.g. disk_used_pct per mount)
    collapse to their single newest point, and the full per-label history is
    still one click away via the per-metric series endpoint."""

    metric: str
    time: datetime
    value: float
    labels: dict


@router.get("/api/v1/agents", response_model=list[AgentOut])
async def list_agents(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[AgentOut]:
    agents = (await session.scalars(select(Agent).order_by(Agent.name))).all()
    return [AgentOut.from_model(a) for a in agents]


async def _get_agent_or_404(session: AsyncSession, agent_id: UUID) -> Agent:
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")
    return agent


@router.get("/api/v1/agents/{agent_id}", response_model=AgentOut)
async def get_agent(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> AgentOut:
    return AgentOut.from_model(await _get_agent_or_404(session, agent_id))


class UpdateGroupsRequest(BaseModel):
    groups: list[str]


@router.patch("/api/v1/agents/{agent_id}/groups", response_model=AgentOut)
async def update_agent_groups(
    agent_id: UUID,
    body: UpdateGroupsRequest,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> AgentOut:
    """Host-group membership (see docs/plan.md's monitoring Block E2/E3) —
    the unit a check_rules row can target with scope_type=group, which a
    host-scoped rule can then override. Replaces the whole list rather
    than adding/removing one at a time, matching how the Settings UI's
    host-groups editor naturally works (a multi-select, not a diff)."""
    agent = await _get_agent_or_404(session, agent_id)
    agent.groups = body.groups
    await session.commit()
    return AgentOut.from_model(agent)


@router.get("/api/v1/agents/{agent_id}/metrics")
async def get_agent_metrics(
    agent_id: UUID,
    metric: str | None = Query(None, description="Metric name to fetch points for; omit for catalog discovery"),
    since: datetime | None = Query(None, description="Only points at or after this time"),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    await _get_agent_or_404(session, agent_id)

    if metric is None:
        # Catalog discovery (see docs/plan.md's "Offene Punkte"): let a
        # caller find out what metric names exist for this agent before
        # asking for any specific one's history.
        names = (
            await session.scalars(
                select(Metric.metric).where(Metric.agent_id == agent_id).distinct().order_by(Metric.metric)
            )
        ).all()
        return {"metrics": list(names)}

    stmt = select(Metric).where(Metric.agent_id == agent_id, Metric.metric == metric)
    if since is not None:
        stmt = stmt.where(Metric.time >= since)
    stmt = stmt.order_by(Metric.time)
    points = (await session.scalars(stmt)).all()
    return {
        "metric": metric,
        "points": [MetricPointOut(time=p.time, value=p.value, labels=p.labels).model_dump() for p in points],
    }


@router.get("/api/v1/agents/{agent_id}/metrics/latest")
async def get_agent_metrics_latest(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """The whole latest-data snapshot in one call: the newest sample of every
    metric this agent has ever reported. Powers the host-detail Metrics tab's
    list view (a metric name + last value + last check per row) so it no
    longer has to fan out one series request per metric just to show a
    value. `DISTINCT ON (metric)` + `time DESC` = Postgres' idiomatic
    latest-per-group; ordered by metric name for a stable list."""
    await _get_agent_or_404(session, agent_id)

    stmt = (
        select(Metric)
        .where(Metric.agent_id == agent_id)
        .order_by(Metric.metric, Metric.time.desc())
        .distinct(Metric.metric)
    )
    rows = (await session.scalars(stmt)).all()
    return {
        "metrics": [
            LatestMetricOut(metric=r.metric, time=r.time, value=r.value, labels=r.labels).model_dump() for r in rows
        ]
    }
