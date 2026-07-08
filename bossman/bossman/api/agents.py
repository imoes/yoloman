"""GET /api/v1/agents, /api/v1/agents/{id}, and /api/v1/agents/{id}/metrics
— the fleet inventory + per-agent metric history views (see docs/plan.md's
Bossman plan, section B.7). These serve Bossman's own already-aggregated
Postgres data (see services/poller.py) — never a live pull from the agent
itself, which is exactly the point of polling ahead of time.
"""

from __future__ import annotations

import asyncio
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.api.auth import get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent, Metric
from bossman.db.session import get_session
from bossman.services.metrics_query import query_series
from bossman.services.poller import PollResult, poll_agent

router = APIRouter()


def get_session_factory(request: Request) -> async_sessionmaker[AsyncSession]:
    return request.app.state.session_factory


def _resolve_dns_name(agent: Agent) -> str | None:
    """A resolvable host name for `agent`, even when it has no `address`
    (satellites polled through a proxy carry none). Prefers the host part of
    `address`, then the inventory hostname (facts.os.hostname). This is what
    lets a run/inventory view show a DNS name instead of a blank for a
    satellite whose only identity is what its own inventory reported."""
    if agent.address:
        # Strip a trailing :port so the run/inventory view shows the host, not host:port.
        host = agent.address.rsplit(":", 1)[0] if ":" in agent.address else agent.address
        if host:
            return host
    os_facts = (agent.facts or {}).get("os") or {}
    hostname = os_facts.get("hostname")
    return hostname or None


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
    # Block K7 (tagging): name or name:value pairs, inherited onto every
    # problem this host raises.
    tags: dict
    # Block L3d: which OU the host is placed in (AD-style, exactly one) —
    # NULL = unassigned. Drives the host-placement tree.
    ou_id: UUID | None
    # A resolvable name for the host even when `address` is null (a satellite
    # polled through a proxy has no direct address). Falls back to the
    # inventory hostname (facts.os.hostname), so a run/inventory view can show
    # a DNS name instead of a blank. None only when neither is known.
    dns_name: str | None

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
            tags=agent.tags or {},
            ou_id=agent.ou_id,
            dns_name=_resolve_dns_name(agent),
        )


class MetricPointOut(BaseModel):
    time: datetime
    value: float
    labels: dict
    # Populated only for the hourly/daily tiers (Block K1b) — the
    # consolidated bucket's spread; None for a true raw sample.
    min_value: float | None = None
    max_value: float | None = None


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


# Tables whose FK to agents is NO ACTION (verified against the live schema):
# they won't cascade on an agent delete, so they're cleared explicitly, in
# FK-safe order, before the agent row goes. Everything else
# (agent_acks/agent_config_delivery/compiled_host_state/graph_items/
# host_group_members/orchestration_plan_links) is ON DELETE CASCADE and goes
# automatically. metrics + service_state_history are TimescaleDB hypertables,
# which is exactly why a plain FK-cascade wasn't put on them and we delete
# by agent_id here instead. plan_run_steps cascades from plan_runs.
_AGENT_CHILD_DELETES = (
    "DELETE FROM host_edges WHERE src_agent_id = :id OR dst_agent_id = :id",
    "DELETE FROM connection_events WHERE src_agent_id = :id",
    "DELETE FROM plan_runs WHERE agent_id = :id",
    "DELETE FROM downtimes WHERE agent_id = :id",
    "DELETE FROM service_state_history WHERE agent_id = :id",
    "DELETE FROM services WHERE agent_id = :id",
    "DELETE FROM metrics WHERE agent_id = :id",
)


@router.delete("/api/v1/agents/{agent_id}", status_code=204)
async def delete_agent(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> None:
    """Remove a host (agent) and everything it owns. Satellites that used this
    agent as their proxy parent are orphaned (parent_agent_id → NULL), not
    deleted — deleting a proxy must not silently take its satellites with it.
    All in one transaction, so a mid-delete failure leaves the host intact."""
    agent = await _get_agent_or_404(session, agent_id)
    params = {"id": str(agent_id)}
    # Orphan any satellites polled through this agent (self-referential FK).
    await session.execute(
        text("UPDATE agents SET parent_agent_id = NULL WHERE parent_agent_id = :id"), params
    )
    for stmt in _AGENT_CHILD_DELETES:
        await session.execute(text(stmt), params)
    await session.delete(agent)  # cascade clears the ON DELETE CASCADE tables
    await session.commit()


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


class UpdateTagsRequest(BaseModel):
    tags: dict[str, str]


@router.patch("/api/v1/agents/{agent_id}/tags", response_model=AgentOut)
async def update_agent_tags(
    agent_id: UUID,
    body: UpdateTagsRequest,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> AgentOut:
    """Block K7 (Zabbix gap-analysis, tagging): name or name:value host
    tags (empty-string value = name-only), inherited onto every problem
    this host raises (GET /api/v1/problems?tag=) and matchable by
    NotificationRule.tag_filter. Replaces the whole dict, matching
    update_agent_groups's replace-not-diff shape."""
    agent = await _get_agent_or_404(session, agent_id)
    agent.tags = body.tags
    await session.commit()
    return AgentOut.from_model(agent)


class MassUpdateGroupsRequest(BaseModel):
    agent_ids: list[UUID]
    op: str  # add | replace | remove
    groups: list[str]


@router.post("/api/v1/agents/mass-update/groups", response_model=list[AgentOut])
async def mass_update_agent_groups(
    body: MassUpdateGroupsRequest,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[AgentOut]:
    """Zabbix gap-analysis Block K2c ("Mass update"): bulk-edit host-group
    membership across many selected agents in one call, instead of one
    PATCH per host. Scoped to the one field Bossman's Agent model actually
    has a bulk-editable equivalent for today (groups) — templates/macros/
    inventory/encryption mass-editing has no Bossman counterpart yet (see
    docs/zabbix-gap-analysis.md's Batch 2)."""
    if body.op not in ("add", "replace", "remove"):
        raise HTTPException(status_code=422, detail="op must be one of: add, replace, remove")
    if not body.agent_ids:
        raise HTTPException(status_code=422, detail="agent_ids must not be empty")

    agents = (await session.scalars(select(Agent).where(Agent.id.in_(body.agent_ids)))).all()
    found_ids = {a.id for a in agents}
    missing = set(body.agent_ids) - found_ids
    if missing:
        raise HTTPException(status_code=404, detail=f"no such agent(s): {sorted(str(m) for m in missing)}")

    for agent in agents:
        if body.op == "replace":
            agent.groups = list(body.groups)
        elif body.op == "add":
            agent.groups = list(dict.fromkeys([*agent.groups, *body.groups]))  # dedupe, preserve order
        else:  # remove
            agent.groups = [g for g in agent.groups if g not in body.groups]

    await session.commit()
    return [AgentOut.from_model(a) for a in agents]


@router.post("/api/v1/agents/{agent_id}/poll-now")
async def poll_agent_now(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    session_factory: async_sessionmaker[AsyncSession] = Depends(get_session_factory),
    settings: Settings = Depends(get_settings),
    client_factory=Depends(get_client_factory),
    _identity=Depends(get_current_identity),
) -> dict:
    """Zabbix gap-analysis Block K5 ("Execute now"): force one agent to be
    polled immediately instead of waiting for the next
    settings.poll_interval_seconds tick — the same poll_agent the
    background loop uses (metrics/edges/hosts-overview pull, state
    evaluation, notification dispatch), just triggered on demand."""
    await _get_agent_or_404(session, agent_id)
    semaphore = asyncio.Semaphore(1)
    result: PollResult = await poll_agent(session_factory, agent_id, settings, semaphore, client_factory)
    return {
        "agent_id": result.agent_id,
        "agent_name": result.agent_name,
        "metrics_written": result.metrics_written,
        "satellites_discovered": result.satellites_discovered,
        "edges_written": result.edges_written,
        "errors": result.errors,
    }


@router.get("/api/v1/agents/{agent_id}/metrics")
async def get_agent_metrics(
    agent_id: UUID,
    metric: str | None = Query(None, description="Metric name to fetch points for; omit for catalog discovery"),
    since: datetime | None = Query(None, description="Only points at or after this time"),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
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

    # Block K1b: a `since` reaching further back than raw metrics' 14-day
    # TimescaleDB retention transparently reads the metrics_hourly/
    # metrics_daily continuous aggregates instead of coming back empty.
    tier, points = await query_series(session, settings, agent_id, metric, since)
    return {
        "metric": metric,
        "resolution": tier,
        "points": [
            MetricPointOut(
                time=p.time, value=p.value, labels=p.labels, min_value=p.min_value, max_value=p.max_value
            ).model_dump()
            for p in points
        ],
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
