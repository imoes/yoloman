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
from bossman.db.models import DEFAULT_TENANT_ID, CheckRule, Downtime, Metric, OUNode, Service
from bossman.db.session import get_session
from bossman.services.reconciler import enqueue_policy_event
from bossman.services.monitoring import (
    ServiceView,
    acknowledge_service,
    compute_availability,
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


# Human-readable names + units for the metrics the built-in agent collectors
# emit (Block L3c: the threshold dialog's live metric search). Anything not
# listed falls back to a titleized metric key. Kept here (not the DB) because
# it's presentation, not data — the *available* metrics come from the DB.
_METRIC_DISPLAY: dict[str, tuple[str, str]] = {
    "cpu_pct": ("CPU usage", "%"),
    "load1": ("Load average (1 min)", ""),
    "load5": ("Load average (5 min)", ""),
    "load15": ("Load average (15 min)", ""),
    "mem_used_pct": ("Memory used", "%"),
    "mem_pct": ("Memory used", "%"),
    "swap_used_pct": ("Swap used", "%"),
    "disk_used_pct": ("Disk used", "%"),
    "disk_io_util_pct": ("Disk I/O utilization", "%"),
    "net_rx_bytes": ("Network received", "bytes/s"),
    "net_tx_bytes": ("Network sent", "bytes/s"),
    "uptime_seconds": ("Uptime", "s"),
    "process_count": ("Process count", ""),
}


class MetricCatalogEntry(BaseModel):
    metric: str
    display_name: str
    unit: str


@router.get("/api/v1/metric-catalog", response_model=list[MetricCatalogEntry])
async def metric_catalog(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[MetricCatalogEntry]:
    """Every distinct metric actually collected across the fleet (from the
    `metrics` hypertable) with a human-readable display name — powers the
    threshold dialog's live metric search (Block L3c). The display name
    describes the METRIC (built-in map, then a titleized fallback), never a
    check-rule's service_name — a rule name like "... check" is about a rule,
    not the metric, and leaked the word "check" into the metric list."""
    metrics = sorted((await session.scalars(select(Metric.metric).distinct())).all())
    out: list[MetricCatalogEntry] = []
    for m in metrics:
        # Skip the derived per-check state series (check_<name>_state, emitted
        # by CheckStatusMetricName): they're a check's own 0/1/2/3 output, not
        # a measurable metric you'd threshold — they only cluttered the metric
        # search with "Check … state" entries.
        if m.startswith("check_") and m.endswith("_state"):
            continue
        if m in _METRIC_DISPLAY:
            display, unit = _METRIC_DISPLAY[m]
        else:
            display, unit = m.replace("_", " ").replace("pct", "%").strip().capitalize(), ""
        out.append(MetricCatalogEntry(metric=m, display_name=display, unit=unit))
    return out


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
    # Block K4: the value-mapped label for `value`, via the owning
    # CheckRule's attached ValueMap (e.g. 0 -> "Down"); null if no map is
    # attached or the rule isn't materializing this service.
    mapped_value: str | None

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
            mapped_value=view.mapped_value,
        )


@router.get("/api/v1/problems", response_model=list[ServiceOut])
async def list_problems(
    state: str | None = Query(None, description="Filter to one state: WARN|CRIT|UNKNOWN"),
    host: str | None = Query(None, description="Filter to one host name"),
    acknowledged: bool | None = Query(None, description="Filter by acknowledged flag"),
    include_downtime: bool = Query(False, description="Include services currently covered by a downtime"),
    tag: str | None = Query(None, description="Filter by host tag: 'name' (any value) or 'name:value' (exact)"),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[ServiceOut]:
    views = await query_problems(
        session, state=state, host=host, acknowledged=acknowledged, include_downtime=include_downtime, tag=tag
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


class AvailabilitySliceOut(BaseModel):
    state: str
    seconds: float
    percent: float


class AvailabilityOut(BaseModel):
    agent_id: UUID
    service_name: str
    start: datetime
    end: datetime
    window_seconds: float
    monitored_seconds: float
    ok_percent: float
    state_changes: int
    slices: list[AvailabilitySliceOut]


@router.get(
    "/api/v1/agents/{agent_id}/services/{service_name:path}/availability",
    response_model=AvailabilityOut,
)
async def get_service_availability(
    agent_id: UUID,
    service_name: str,
    hours: float = Query(24.0, gt=0, le=8784, description="Look-back window in hours (default 24h)"),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> AvailabilityOut:
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=hours)
    report = await compute_availability(session, agent_id, service_name, start, end)
    return AvailabilityOut(
        agent_id=report.agent_id,
        service_name=report.service_name,
        start=report.start,
        end=report.end,
        window_seconds=report.window_seconds,
        monitored_seconds=report.monitored_seconds,
        ok_percent=report.ok_percent,
        state_changes=report.state_changes,
        slices=[
            AvailabilitySliceOut(state=s.state, seconds=s.seconds, percent=s.percent) for s in report.slices
        ],
    )


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
    # Block L3a: OU-scoped rules + GPO precedence. scope_type='ou' pins the
    # rule to scope_ou_id; enforced/link_order drive inheritance resolution.
    scope_ou_id: UUID | None = None
    enforced: bool = False
    link_order: int = 100
    # Optional label pin (a disk mount) — see CheckRule.label_value (H6).
    label_value: str | None = None
    # Consecutive non-OK checks before hard (Block H7); null = global default.
    max_attempts: int | None = None
    enabled: bool = True
    # Block K4: an optional attached ValueMap, shown on the materialized
    # Service alongside its raw value.
    value_map_id: UUID | None = None
    # Block K6: hysteresis — see CheckRule.recovery_threshold.
    recovery_threshold: float | None = None
    # Block K8: trigger dependency — see CheckRule.depends_on_service_name.
    depends_on_service_name: str | None = None
    # Block K9: composite/multi-metric conditions — see CheckRule.extra_conditions.
    extra_conditions: list[dict] | None = None
    condition_logic: str = "AND"


class CheckRuleOut(BaseModel):
    id: UUID
    service_name: str
    metric: str
    comparison: str
    warn_threshold: float | None
    crit_threshold: float | None
    scope_type: str
    scope_value: str | None
    scope_ou_id: UUID | None
    enforced: bool
    link_order: int
    label_value: str | None
    max_attempts: int | None
    is_default: bool
    enabled: bool
    created_at: datetime
    value_map_id: UUID | None
    recovery_threshold: float | None
    depends_on_service_name: str | None
    extra_conditions: list[dict] | None
    condition_logic: str

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
            scope_ou_id=r.scope_ou_id,
            enforced=r.enforced,
            link_order=r.link_order,
            label_value=r.label_value,
            max_attempts=r.max_attempts,
            is_default=r.is_default,
            enabled=r.enabled,
            created_at=r.created_at,
            value_map_id=r.value_map_id,
            recovery_threshold=r.recovery_threshold,
            depends_on_service_name=r.depends_on_service_name,
            extra_conditions=r.extra_conditions,
            condition_logic=r.condition_logic,
        )


def _validate_scope(scope_type: str, scope_value: str | None, scope_ou_id: UUID | None = None) -> None:
    if scope_type not in ("global", "group", "host", "ou"):
        raise HTTPException(status_code=422, detail="scope_type must be one of global|group|host|ou")
    if scope_type == "ou":
        if scope_ou_id is None:
            raise HTTPException(status_code=422, detail="scope_ou_id is required when scope_type is 'ou'")
        if scope_value is not None:
            raise HTTPException(status_code=422, detail="scope_value must be null when scope_type is 'ou'")
        return
    if scope_ou_id is not None:
        raise HTTPException(status_code=422, detail="scope_ou_id is only valid when scope_type is 'ou'")
    if scope_type == "global" and scope_value is not None:
        raise HTTPException(status_code=422, detail="scope_value must be null when scope_type is global")
    if scope_type in ("group", "host") and not scope_value:
        raise HTTPException(status_code=422, detail=f"scope_value is required when scope_type is {scope_type!r}")


async def _enqueue_rule_change(session: AsyncSession) -> None:
    """Block L4: record a transactional-outbox event so the reconciler
    recompiles + re-delivers affected hosts' desired state. scope='tenant'
    (recompile the whole default tenant) — correct, if broader than strictly
    needed; precise per-OU blast-radius targeting is a later refinement."""
    await enqueue_policy_event(session, UUID(DEFAULT_TENANT_ID), "rule_changed", scope="tenant")


def _validate_composite(body: CheckRuleIn) -> None:
    if body.condition_logic not in ("AND", "OR"):
        raise HTTPException(status_code=422, detail="condition_logic must be one of AND|OR")
    for cond in body.extra_conditions or []:
        if "metric" not in cond or "comparison" not in cond:
            raise HTTPException(status_code=422, detail="each extra_conditions entry needs metric and comparison")
        if cond["comparison"] not in ("gt", "lt", "ge", "le", "eq", "ne"):
            raise HTTPException(status_code=422, detail=f"invalid comparison in extra_conditions: {cond['comparison']!r}")


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
    _validate_scope(body.scope_type, body.scope_value, body.scope_ou_id)
    _validate_composite(body)
    if body.scope_ou_id is not None and await session.get(OUNode, body.scope_ou_id) is None:
        raise HTTPException(status_code=422, detail=f"no such OU {body.scope_ou_id}")

    rule = CheckRule(
        service_name=body.service_name,
        metric=body.metric,
        comparison=body.comparison,
        warn_threshold=body.warn_threshold,
        crit_threshold=body.crit_threshold,
        scope_type=body.scope_type,
        scope_value=body.scope_value,
        scope_ou_id=body.scope_ou_id,
        enforced=body.enforced,
        link_order=body.link_order,
        label_value=body.label_value,
        max_attempts=body.max_attempts,
        enabled=body.enabled,
        value_map_id=body.value_map_id,
        recovery_threshold=body.recovery_threshold,
        depends_on_service_name=body.depends_on_service_name,
        extra_conditions=body.extra_conditions,
        condition_logic=body.condition_logic,
    )
    session.add(rule)
    await _enqueue_rule_change(session)
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
    if rule.template_id is not None:
        # Block K12: this row is generated from a Template's TemplateRule —
        # a direct edit would just get overwritten on the next
        # materialization. Edit the owning template instead.
        raise HTTPException(
            status_code=409,
            detail=f"check rule {rule_id} is managed by template {rule.template_id} — edit the template instead",
        )
    if body.comparison not in ("gt", "lt", "ge", "le", "eq", "ne"):
        raise HTTPException(status_code=422, detail="comparison must be one of gt|lt|ge|le|eq|ne")
    _validate_scope(body.scope_type, body.scope_value, body.scope_ou_id)
    _validate_composite(body)
    if body.scope_ou_id is not None and await session.get(OUNode, body.scope_ou_id) is None:
        raise HTTPException(status_code=422, detail=f"no such OU {body.scope_ou_id}")

    rule.service_name = body.service_name
    rule.metric = body.metric
    rule.comparison = body.comparison
    rule.warn_threshold = body.warn_threshold
    rule.crit_threshold = body.crit_threshold
    rule.scope_type = body.scope_type
    rule.scope_value = body.scope_value
    rule.scope_ou_id = body.scope_ou_id
    rule.enforced = body.enforced
    rule.link_order = body.link_order
    rule.label_value = body.label_value
    rule.max_attempts = body.max_attempts
    rule.enabled = body.enabled
    rule.value_map_id = body.value_map_id
    rule.recovery_threshold = body.recovery_threshold
    rule.depends_on_service_name = body.depends_on_service_name
    rule.extra_conditions = body.extra_conditions
    rule.condition_logic = body.condition_logic
    await _enqueue_rule_change(session)
    await session.commit()
    return CheckRuleOut.from_model(rule)


class CheckRulePatch(BaseModel):
    """Partial GPO-flag update (Block L3a) — powers the tree console's
    Enforced / Enabled context-menu toggles without resending the whole rule."""

    enforced: bool | None = None
    enabled: bool | None = None
    link_order: int | None = None


@router.patch("/api/v1/check-rules/{rule_id}", response_model=CheckRuleOut)
async def patch_check_rule(
    rule_id: UUID,
    body: CheckRulePatch,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> CheckRuleOut:
    rule = await session.get(CheckRule, rule_id)
    if rule is None:
        raise HTTPException(status_code=404, detail=f"no such check rule {rule_id}")
    if rule.template_id is not None:
        raise HTTPException(
            status_code=409,
            detail=f"check rule {rule_id} is managed by template {rule.template_id} — edit the template instead",
        )
    if body.enforced is not None:
        rule.enforced = body.enforced
    if body.enabled is not None:
        rule.enabled = body.enabled
    if body.link_order is not None:
        rule.link_order = body.link_order
    await _enqueue_rule_change(session)
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
    if rule.template_id is not None:
        raise HTTPException(
            status_code=409,
            detail=f"check rule {rule_id} is managed by template {rule.template_id} — unlink the template instead",
        )
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
    await _enqueue_rule_change(session)
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
