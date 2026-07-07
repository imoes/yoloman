"""The CheckMK-style monitoring REST surface (see docs/plan.md's
monitoring Block E3): GET /api/v1/problems (the "unbehandelte Probleme"
view every real monitoring system leads with), per-host services,
acknowledge/unacknowledge, downtimes, check-rule CRUD, and a fleet-wide
summary for the overview page. Every route auth-gated like the rest of
Block B7's REST surface.

Query/mutation logic lives in services/monitoring.py, not here — the same
functions back the MCP tools in mcp/server.py (the MCP-native admin entry
point this project is built around), so the two facades never diverge.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import CheckRule, Downtime, Service
from bossman.db.session import get_session
from bossman.services.monitoring import (
    ServiceView,
    acknowledge_service,
    create_downtime,
    fleet_hosts,
    fleet_summary,
    query_agent_services,
    query_problems,
    service_state_history,
    to_view,
    unacknowledge_service,
)

router = APIRouter()


class ServiceOut(BaseModel):
    id: UUID
    agent_id: UUID
    agent_name: str
    name: str
    metric: str
    state: str
    value: float | None
    output: str
    last_state_change: datetime
    last_checked: datetime
    state_type: str
    attempt: int
    max_attempts: int
    is_flapping: bool
    acknowledged: bool
    ack_comment: str | None
    ack_by: str | None
    ack_expires_at: datetime | None
    in_downtime: bool

    @classmethod
    def from_view(cls, view: ServiceView) -> "ServiceOut":
        s = view.service
        return cls(
            id=s.id,
            agent_id=s.agent_id,
            agent_name=view.agent_name,
            name=s.name,
            metric=s.metric,
            state=s.state,
            value=s.value,
            output=s.output,
            last_state_change=s.last_state_change,
            last_checked=s.last_checked,
            state_type=s.state_type,
            attempt=s.attempt,
            max_attempts=s.max_attempts,
            is_flapping=s.is_flapping,
            acknowledged=s.acknowledged,
            ack_comment=s.ack_comment,
            ack_by=s.ack_by,
            ack_expires_at=s.ack_expires_at,
            in_downtime=view.in_downtime,
        )


@router.get("/api/v1/problems", response_model=list[ServiceOut])
async def list_problems(
    state: str | None = Query(None, description="Filter to one state: WARN|CRIT|UNKNOWN"),
    host: str | None = Query(None, description="Filter to one host name"),
    acknowledged: bool | None = Query(None, description="Filter by acknowledged flag"),
    include_downtime: bool = Query(False, description="Include services currently covered by a downtime"),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[ServiceOut]:
    views = await query_problems(
        session, state=state, host=host, acknowledged=acknowledged, include_downtime=include_downtime
    )
    return [ServiceOut.from_view(v) for v in views]


@router.get("/api/v1/agents/{agent_id}/services", response_model=list[ServiceOut])
async def list_agent_services(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[ServiceOut]:
    views = await query_agent_services(session, agent_id)
    if views is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")
    return [ServiceOut.from_view(v) for v in views]


class ServiceHistoryPointOut(BaseModel):
    time: datetime
    state: str
    value: float | None


@router.get("/api/v1/agents/{agent_id}/services/{service_name:path}/history", response_model=list[ServiceHistoryPointOut])
async def get_service_history(
    agent_id: UUID,
    service_name: str,
    limit: int = Query(200, ge=1, le=1000),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[ServiceHistoryPointOut]:
    rows = await service_state_history(session, agent_id, service_name, limit=limit)
    return [ServiceHistoryPointOut(time=r.time, state=r.state, value=r.value) for r in rows]


class AcknowledgeRequest(BaseModel):
    comment: str = ""
    # CheckMK's "acknowledge for a limited time" (Block H5): after this many
    # minutes the ack lapses and the problem resurfaces. None/0 = indefinite
    # (the previous behavior — valid until the next state change).
    expire_after_minutes: int | None = None


@router.post("/api/v1/services/{service_id}/acknowledge", response_model=ServiceOut)
async def acknowledge_service_route(
    service_id: UUID,
    body: AcknowledgeRequest,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> ServiceOut:
    expires_at = None
    if body.expire_after_minutes and body.expire_after_minutes > 0:
        expires_at = datetime.now(timezone.utc) + timedelta(minutes=body.expire_after_minutes)
    service = await acknowledge_service(session, service_id, body.comment, identity.name, expires_at)
    if service is None:
        raise HTTPException(status_code=404, detail=f"no such service {service_id}")
    return ServiceOut.from_view(await to_view(session, service))


@router.delete("/api/v1/services/{service_id}/acknowledge", response_model=ServiceOut)
async def unacknowledge_service_route(
    service_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> ServiceOut:
    service = await unacknowledge_service(session, service_id)
    if service is None:
        raise HTTPException(status_code=404, detail=f"no such service {service_id}")
    return ServiceOut.from_view(await to_view(session, service))


class DowntimeIn(BaseModel):
    agent_id: UUID
    service_name: str | None = None
    starts_at: datetime
    ends_at: datetime
    comment: str = ""


class DowntimeOut(BaseModel):
    id: UUID
    agent_id: UUID
    service_name: str | None
    starts_at: datetime
    ends_at: datetime
    comment: str
    created_by: str | None
    created_at: datetime

    @classmethod
    def from_model(cls, d: Downtime) -> "DowntimeOut":
        return cls(
            id=d.id,
            agent_id=d.agent_id,
            service_name=d.service_name,
            starts_at=d.starts_at,
            ends_at=d.ends_at,
            comment=d.comment,
            created_by=d.created_by,
            created_at=d.created_at,
        )


@router.get("/api/v1/downtimes", response_model=list[DowntimeOut])
async def list_downtimes(
    agent_id: UUID | None = Query(None),
    active_only: bool = Query(False, description="Only downtimes whose window covers right now"),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[DowntimeOut]:
    stmt = select(Downtime)
    if agent_id is not None:
        stmt = stmt.where(Downtime.agent_id == agent_id)
    if active_only:
        now = datetime.now(timezone.utc)
        stmt = stmt.where(Downtime.starts_at <= now, Downtime.ends_at >= now)
    stmt = stmt.order_by(Downtime.starts_at.desc())
    rows = (await session.scalars(stmt)).all()
    return [DowntimeOut.from_model(d) for d in rows]


@router.post("/api/v1/downtimes", response_model=DowntimeOut)
async def create_downtime_route(
    body: DowntimeIn,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> DowntimeOut:
    try:
        downtime = await create_downtime(
            session,
            agent_id=body.agent_id,
            service_name=body.service_name,
            starts_at=body.starts_at,
            ends_at=body.ends_at,
            comment=body.comment,
            created_by=identity.name,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    if downtime is None:
        raise HTTPException(status_code=404, detail=f"no such agent {body.agent_id}")
    return DowntimeOut.from_model(downtime)


@router.delete("/api/v1/downtimes/{downtime_id}", status_code=204)
async def delete_downtime(
    downtime_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> None:
    downtime = await session.get(Downtime, downtime_id)
    if downtime is None:
        raise HTTPException(status_code=404, detail=f"no such downtime {downtime_id}")
    await session.delete(downtime)
    await session.commit()


class CheckRuleIn(BaseModel):
    service_name: str
    metric: str
    comparison: str
    warn_threshold: float | None = None
    crit_threshold: float | None = None
    scope_type: str = "global"
    scope_value: str | None = None
    # Optional label pin (a disk mount) — see CheckRule.label_value (H6).
    label_value: str | None = None
    # Consecutive non-OK checks before hard (Block H7); null = global default.
    max_attempts: int | None = None
    enabled: bool = True


class CheckRuleOut(BaseModel):
    id: UUID
    service_name: str
    metric: str
    comparison: str
    warn_threshold: float | None
    crit_threshold: float | None
    scope_type: str
    scope_value: str | None
    label_value: str | None
    max_attempts: int | None
    is_default: bool
    enabled: bool
    created_at: datetime

    @classmethod
    def from_model(cls, r: CheckRule) -> "CheckRuleOut":
        return cls(
            id=r.id,
            service_name=r.service_name,
            metric=r.metric,
            comparison=r.comparison,
            warn_threshold=r.warn_threshold,
            crit_threshold=r.crit_threshold,
            scope_type=r.scope_type,
            scope_value=r.scope_value,
            label_value=r.label_value,
            max_attempts=r.max_attempts,
            is_default=r.is_default,
            enabled=r.enabled,
            created_at=r.created_at,
        )


def _validate_scope(scope_type: str, scope_value: str | None) -> None:
    if scope_type not in ("global", "group", "host"):
        raise HTTPException(status_code=422, detail="scope_type must be one of global|group|host")
    if scope_type == "global" and scope_value is not None:
        raise HTTPException(status_code=422, detail="scope_value must be null when scope_type is global")
    if scope_type in ("group", "host") and not scope_value:
        raise HTTPException(status_code=422, detail=f"scope_value is required when scope_type is {scope_type!r}")


@router.get("/api/v1/check-rules", response_model=list[CheckRuleOut])
async def list_check_rules(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[CheckRuleOut]:
    rules = (await session.scalars(select(CheckRule).order_by(CheckRule.created_at.desc()))).all()
    return [CheckRuleOut.from_model(r) for r in rules]


@router.post("/api/v1/check-rules", response_model=CheckRuleOut)
async def create_check_rule(
    body: CheckRuleIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> CheckRuleOut:
    if body.comparison not in ("gt", "lt", "ge", "le", "eq", "ne"):
        raise HTTPException(status_code=422, detail="comparison must be one of gt|lt|ge|le|eq|ne")
    _validate_scope(body.scope_type, body.scope_value)

    rule = CheckRule(
        service_name=body.service_name,
        metric=body.metric,
        comparison=body.comparison,
        warn_threshold=body.warn_threshold,
        crit_threshold=body.crit_threshold,
        scope_type=body.scope_type,
        scope_value=body.scope_value,
        label_value=body.label_value,
        max_attempts=body.max_attempts,
        enabled=body.enabled,
    )
    session.add(rule)
    await session.commit()
    return CheckRuleOut.from_model(rule)


@router.put("/api/v1/check-rules/{rule_id}", response_model=CheckRuleOut)
async def update_check_rule(
    rule_id: UUID,
    body: CheckRuleIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> CheckRuleOut:
    rule = await session.get(CheckRule, rule_id)
    if rule is None:
        raise HTTPException(status_code=404, detail=f"no such check rule {rule_id}")
    if body.comparison not in ("gt", "lt", "ge", "le", "eq", "ne"):
        raise HTTPException(status_code=422, detail="comparison must be one of gt|lt|ge|le|eq|ne")
    _validate_scope(body.scope_type, body.scope_value)

    rule.service_name = body.service_name
    rule.metric = body.metric
    rule.comparison = body.comparison
    rule.warn_threshold = body.warn_threshold
    rule.crit_threshold = body.crit_threshold
    rule.scope_type = body.scope_type
    rule.scope_value = body.scope_value
    rule.label_value = body.label_value
    rule.max_attempts = body.max_attempts
    rule.enabled = body.enabled
    await session.commit()
    return CheckRuleOut.from_model(rule)


@router.delete("/api/v1/check-rules/{rule_id}", status_code=204)
async def delete_check_rule(
    rule_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> None:
    rule = await session.get(CheckRule, rule_id)
    if rule is None:
        raise HTTPException(status_code=404, detail=f"no such check rule {rule_id}")
    # Delete the services this rule materialized first (services.rule_id
    # FKs check_rules.id, so a bare rule delete 500s once it owns any
    # service — Block H6/H7). The agent's built-in check, if any, simply
    # re-creates its own reading on the next poll now that no rule owns it.
    owned = (await session.scalars(select(Service).where(Service.rule_id == rule_id))).all()
    for svc in owned:
        await session.delete(svc)
    # Flush the child deletes before the parent: there's no ORM relationship
    # declared between Service.rule_id and CheckRule, so the unit of work
    # won't order these on its own and would otherwise hit the FK.
    await session.flush()
    await session.delete(rule)
    await session.commit()


class FleetSummaryOut(BaseModel):
    hosts_total: int
    hosts_by_enrollment: dict[str, int]
    services_by_state: dict[str, int]
    open_problems: int


@router.get("/api/v1/fleet/summary", response_model=FleetSummaryOut)
async def fleet_summary_route(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> FleetSummaryOut:
    summary = await fleet_summary(session)
    return FleetSummaryOut(
        hosts_total=summary.hosts_total,
        hosts_by_enrollment=summary.hosts_by_enrollment,
        services_by_state=summary.services_by_state,
        open_problems=summary.open_problems,
    )


class FleetHostOut(BaseModel):
    id: UUID
    name: str
    parent_agent_id: UUID | None
    parent_name: str | None
    mode: str
    enrollment_state: str
    last_seen_at: datetime | None
    state_rollup: str
    cpu_load: float | None
    mem_used_pct: float | None
    disk_used_pct_max: float | None
    service_counts: dict[str, int]


@router.get("/api/v1/fleet/hosts", response_model=list[FleetHostOut])
async def fleet_hosts_route(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[FleetHostOut]:
    """The host-overview table's data source (see docs/plan.md's
    monitoring-cockpit ergänzung Block F2/F3): one row per host — every
    directly enrolled agent and every satellite discovered behind a
    proxy — with real CPU/memory/disk values and a CheckMK-style state
    rollup, in a single call instead of a per-host metrics fan-out."""
    hosts = await fleet_hosts(session)
    return [
        FleetHostOut(
            id=h.id,
            name=h.name,
            parent_agent_id=h.parent_agent_id,
            parent_name=h.parent_name,
            mode=h.mode,
            enrollment_state=h.enrollment_state,
            last_seen_at=h.last_seen_at,
            state_rollup=h.state_rollup,
            cpu_load=h.cpu_load,
            mem_used_pct=h.mem_used_pct,
            disk_used_pct_max=h.disk_used_pct_max,
            service_counts=h.service_counts,
        )
        for h in hosts
    ]
