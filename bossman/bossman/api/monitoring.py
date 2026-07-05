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

from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import CheckRule, Downtime
from bossman.db.session import get_session
from bossman.services.monitoring import (
    ServiceView,
    acknowledge_service,
    create_downtime,
    fleet_summary,
    query_agent_services,
    query_problems,
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
    acknowledged: bool
    ack_comment: str | None
    ack_by: str | None
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
            acknowledged=s.acknowledged,
            ack_comment=s.ack_comment,
            ack_by=s.ack_by,
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


class AcknowledgeRequest(BaseModel):
    comment: str = ""


@router.post("/api/v1/services/{service_id}/acknowledge", response_model=ServiceOut)
async def acknowledge_service_route(
    service_id: UUID,
    body: AcknowledgeRequest,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> ServiceOut:
    service = await acknowledge_service(session, service_id, body.comment, identity.name)
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
