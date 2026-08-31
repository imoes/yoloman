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

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.etag import check_if_match, compute_version
from bossman.api.auth import get_current_identity
from bossman.db.models import DEFAULT_TENANT_ID, Agent, CheckRule, CheckRuleOuLink, Downtime, Metric, OUNode, Service, Site
from bossman.db.session import get_session
from bossman.services.auth import user_can_manage_agent
from bossman.services.metrics_query import is_measurable
from bossman.services.reconciler import enqueue_policy_event
from bossman.services.monitoring import (
    ServiceView,
    acknowledge_service,
    compute_availability,
    create_downtime,
    explain_effective_rules,
    fleet_hosts,
    fleet_summary,
    load_rule_ou_links,
    query_agent_services,
    query_problems,
    service_state_history,
    to_view,
    unacknowledge_service,
)

router = APIRouter()


# Human-readable names, units + a one-line description for the metrics the
# built-in agent collectors emit (Block L3c: the threshold dialog's Miller-list
# metric search — the description renders in smaller text under the name).
# Anything not listed falls back to a titleized metric key. Kept here (not the
# DB) because it's presentation, not data — the *available* metrics come from
# the DB. Tuple: (display_name, unit, description).
_METRIC_DISPLAY: dict[str, tuple[str, str, str]] = {
    "cpu_pct": ("CPU usage", "%", "Percentage of CPU time in use across all cores."),
    "load1": ("Load average (1 min)", "", "Run-queue length averaged over the last minute."),
    "load5": ("Load average (5 min)", "", "Run-queue length averaged over the last 5 minutes."),
    "load15": ("Load average (15 min)", "", "Run-queue length averaged over the last 15 minutes."),
    "mem_used_pct": ("Memory used", "%", "Percentage of physical RAM in use."),
    "mem_pct": ("Memory used", "%", "Percentage of physical RAM in use."),
    "swap_used_pct": ("Swap used", "%", "Percentage of swap space in use."),
    "disk_used_pct": ("Disk used", "%", "Percentage of a filesystem's capacity in use."),
    "disk_io_util_pct": ("Disk I/O utilization", "%", "Fraction of time the disk was busy servicing I/O."),
    "net_rx_bytes": ("Network received", "bytes/s", "Inbound network throughput."),
    "net_tx_bytes": ("Network sent", "bytes/s", "Outbound network throughput."),
    "uptime_seconds": ("Uptime", "s", "Seconds since the host last booted."),
    "process_count": ("Process count", "", "Number of running processes."),
}


class MetricCatalogEntry(BaseModel):
    metric: str
    display_name: str
    unit: str
    description: str = ""


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
        # ONE exclusion rule for every catalog (services/metrics_query.is_measurable): a
        # check's own 0/1/2/3 verdict and the per-PID process_* series are not things a human
        # picks to threshold or plot. This endpoint used to skip only the former while the
        # per-agent catalog skipped only the latter.
        if not is_measurable(m):
            continue
        if m in _METRIC_DISPLAY:
            display, unit, description = _METRIC_DISPLAY[m]
        else:
            display = m.replace("_", " ").replace("pct", "%").strip().capitalize()
            # No curated description — fall back to the raw metric key so the
            # Miller list still shows a secondary line (never a blank one).
            unit, description = "", f"Raw metric: {m}"
        out.append(MetricCatalogEntry(metric=m, display_name=display, unit=unit, description=description))
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
    # F-17: the owning rule's thresholds + comparison, so the UI can show
    # what a service is being graded against (null for rule-less builtins).
    warn_threshold: float | None
    crit_threshold: float | None
    comparison: str | None

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
            warn_threshold=view.warn_threshold,
            crit_threshold=view.crit_threshold,
            comparison=view.comparison,
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
    """Everything currently not OK in the fleet — the problem list.

    WARN, CRIT and UNKNOWN services, **most recently changed state first**,
    filterable by state, host name, acknowledgement and host tag. That ordering is
    deliberate: what just broke is what an operator has not seen yet.

    **Services under an active downtime are excluded unless you ask for them**
    (`include_downtime=true`). That is the point of a downtime: a planned outage is
    not a problem, and a problem list that shows it teaches operators to ignore the
    list. They are excluded, never deleted — the service still has its state, and the
    downtime is why it is not here.

    UNKNOWN is a state, not a gap: it means the check could not produce a verdict, and
    the service's message says why (no data yet, the check was refused, the check
    itself failed). Do not read it as OK.
    """
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
    """Every check result for one host, as service states.

    One row per check assigned to this host: its state, its message, its metrics and
    when it last ran. A host that has just been enrolled legitimately returns an empty
    list — no checks are assigned yet, which is different from all checks passing.

    404 when the agent id does not exist.
    """
    views = await query_agent_services(session, agent_id)
    if views is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")
    return [ServiceOut.from_view(v) for v in views]


class EffectiveRuleCandidateOut(BaseModel):
    """One candidate rule in the effective-parameters view, with its winner
    flag + reason (Block E). scope_label is human-readable (OU path, site name,
    group name, host name, or 'Global')."""

    rule_id: UUID
    scope_type: str
    scope_label: str
    level: int
    enforced: bool
    comparison: str | None
    warn_threshold: float | None
    crit_threshold: float | None
    is_winner: bool
    reason: str


class EffectiveThresholdOut(BaseModel):
    metric: str
    display_name: str
    label_value: str | None
    service_name: str
    candidates: list[EffectiveRuleCandidateOut]


@router.get("/api/v1/agents/{agent_id}/effective-thresholds", response_model=list[EffectiveThresholdOut])
async def get_effective_thresholds(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[EffectiveThresholdOut]:
    """Checkmk's 'effective parameters' page, our way (Block E): for this host,
    every metric that has at least one applicable threshold rule, showing which
    rule WINS and why — plus the losing candidates and the reason each lost.
    OUR precedence is the reverse of Checkmk's: the closest-to-host rule wins
    (host > site > OU-deep > group > global) unless a higher one is enforced."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")

    from bossman.services.compiler import resolve_ou_ancestry, resolve_site_ids

    host_ou_ancestry = await resolve_ou_ancestry(session, agent.ou_id)
    rule_ou_links = await load_rule_ou_links(session)
    host_site_ids = await resolve_site_ids(session, agent)

    rules = list((await session.scalars(select(CheckRule).where(CheckRule.enabled == True))).all())  # noqa: E712
    if not rules:
        return []

    # Human labels: OU path from the ancestry (an OU-scoped rule only matched if
    # its OU is on this host's path), site name from the Sites the host is in.
    ou_path = {ou.id: ou.path for ou in host_ou_ancestry}
    site_name = {
        s.id: s.name
        for s in (await session.scalars(select(Site).where(Site.id.in_(host_site_ids)))).all()
    } if host_site_ids else {}

    def _scope_label(r: CheckRule) -> str:
        if r.scope_type == "global":
            return "Global (whole fleet)"
        if r.scope_type == "host":
            return f"Host {r.scope_value}"
        if r.scope_type == "group":
            return f"Group {r.scope_value}"
        if r.scope_type == "site":
            return f"Site {site_name.get(r.scope_site_id, r.scope_site_id)}"
        if r.scope_type == "ou":
            # The deepest OU of this rule that lies on the host's path (matches
            # the level the resolver used); fall back to the primary scope_ou_id.
            ous = set()
            if r.id is not None:
                ous |= set(rule_ou_links.get(r.id, ()))
            if r.scope_ou_id is not None:
                ous.add(r.scope_ou_id)
            on_path = [o for o in ous if o in ou_path]
            best = max(on_path, key=lambda o: ou_path[o].count("/")) if on_path else None
            return f"OU {ou_path[best]}" if best else "OU"
        return r.scope_type

    # Group rules by (metric, label_value): the poller fans a metric out per
    # label (e.g. disk mount), so a per-label explanation matches what runs.
    from collections import defaultdict

    labels_by_metric: dict[str, set] = defaultdict(set)
    for r in rules:
        labels_by_metric[r.metric].add(r.label_value)

    out: list[EffectiveThresholdOut] = []
    for metric in sorted(labels_by_metric):
        label_values = labels_by_metric[metric]
        # If any rule is label-agnostic (None), evaluate the None series too so a
        # metric with no pinned label still shows its winner.
        candidates_labels = set(label_values)
        candidates_labels.add(None)
        display, _unit, _desc = _METRIC_DISPLAY.get(
            metric, (metric.replace("_", " ").replace("pct", "%").strip().capitalize(), "", "")
        )
        for label_value in sorted(candidates_labels, key=lambda x: (x is not None, x or "")):
            expl = explain_effective_rules(
                rules, agent.name, agent.groups, metric, label_value,
                host_ou_ancestry=host_ou_ancestry, rule_ou_links=rule_ou_links, host_site_ids=host_site_ids,
            )
            if not expl:
                continue
            winner = next((e for e in expl if e.is_winner), None)
            service_name = winner.rule.service_name if winner else (expl[0].rule.service_name)
            out.append(
                EffectiveThresholdOut(
                    metric=metric,
                    display_name=display,
                    label_value=label_value,
                    service_name=service_name,
                    candidates=[
                        EffectiveRuleCandidateOut(
                            rule_id=e.rule.id,
                            scope_type=e.rule.scope_type,
                            scope_label=_scope_label(e.rule),
                            level=e.level,
                            enforced=bool(e.rule.enforced),
                            comparison=e.rule.comparison,
                            warn_threshold=e.rule.warn_threshold,
                            crit_threshold=e.rule.crit_threshold,
                            is_winner=e.is_winner,
                            reason=e.reason,
                        )
                        for e in expl
                    ],
                )
            )
    return out


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
    """This service's confirmed state changes over time.

    **Hard changes only**: a soft flicker that never became a confirmed state is deliberately absent,
    so the timeline shows what an operator would have been told about rather than every wobble the
    poller saw. That is also why an availability figure computed from this is stable.
    """
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
    """How much of the asked-for period this service spent in each state.

    Computed from the confirmed (hard) state history, so it agrees with the timeline rather than
    telling a second story. Time before the service's first record is **not** counted as OK — a
    period nobody measured is not availability, and reporting it as uptime would be flattering
    rather than true.
    """
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
    """Acknowledge a problem: someone has seen it and is dealing with it.

    An acknowledgement does not change the state — the service stays CRIT, because it
    still is CRIT. It records that a human took it, with their name, their comment and
    the time, and it takes the service out of the notification path so the next
    escalation step does not fire. That separation is the point: suppressing the alarm
    must not be the same act as claiming the problem is gone.

    `expire_after_minutes` makes it lapse by itself, which is what you want for "I'll
    look at this after lunch" — an acknowledgement that never expires is how a real
    problem gets forgotten.

    It is also cleared automatically on the next **confirmed (hard) state change** —
    a recovery *or* a fresh problem onset. Both are new occurrences, and a stale
    acknowledgement carrying over into one would silence something nobody has looked
    at. A soft flicker does not clear it.
    """
    expires_at = None
    if body.expire_after_minutes and body.expire_after_minutes > 0:
        expires_at = datetime.now(timezone.utc) + timedelta(minutes=body.expire_after_minutes)
    service = await acknowledge_service(session, service_id, body.comment, identity.name, expires_at)
    if service is None:
        raise HTTPException(status_code=404, detail=f"no such service {service_id}")
    return ServiceOut.from_view(await to_view(session, service))


class BulkAcknowledgeRequest(BaseModel):
    service_ids: list[UUID]
    comment: str = ""
    expire_after_minutes: int | None = None


class BulkAcknowledgeResponse(BaseModel):
    acknowledged: list[str]
    missing: list[str]
    count: int


@router.post("/api/v1/services/acknowledge-bulk", response_model=BulkAcknowledgeResponse)
async def bulk_acknowledge_services(
    body: BulkAcknowledgeRequest,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> BulkAcknowledgeResponse:
    """Acknowledge many problems at once (multi-select on the Problems table),
    the same mutation as the per-service route applied over a list — mirrors
    the mass_update_agent_groups bulk shape. Unknown ids are reported in
    `missing` rather than failing the whole batch."""
    expires_at = None
    if body.expire_after_minutes and body.expire_after_minutes > 0:
        expires_at = datetime.now(timezone.utc) + timedelta(minutes=body.expire_after_minutes)
    acked: list[str] = []
    missing: list[str] = []
    for sid in body.service_ids:
        service = await acknowledge_service(session, sid, body.comment, identity.name, expires_at)
        (acked if service is not None else missing).append(str(sid))
    return BulkAcknowledgeResponse(acknowledged=acked, missing=missing, count=len(acked))


@router.delete("/api/v1/services/{service_id}/acknowledge", response_model=ServiceOut)
async def unacknowledge_service_route(
    service_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> ServiceOut:
    """Take the acknowledgement back — the problem returns to the notification path
    with its comment and history intact. Used when whoever took it cannot finish it."""
    service = await unacknowledge_service(session, service_id)
    if service is None:
        raise HTTPException(status_code=404, detail=f"no such service {service_id}")
    return ServiceOut.from_view(await to_view(session, service))


@router.delete("/api/v1/services/{service_id}", status_code=204)
async def delete_service_route(
    service_id: UUID,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> None:
    """Delete one service row — for orphaned/stale services that no producer
    refreshes any more (a renamed check's leftover row like an old "Link state",
    or a service left behind after its assignment/rule was removed).

    Deletes ONLY the `services` row (a small, plain table — a cheap normal
    DELETE). It deliberately does NOT touch `service_state_history`: that is a
    TimescaleDB hypertable, and deleting from a time-series hypertable forces its
    (potentially compressed) chunks to decompress and bloats the database. The
    stale timeline is harmless and its 30-day retention policy drops it on its
    own. Caveat: if an ACTIVE assignment, check rule, or agent builtin still
    materialises this service, the next poll recreates it — remove that producer
    first (unassign the check / delete the rule) to make the deletion stick."""
    service = await session.get(Service, service_id)
    if service is None:
        raise HTTPException(status_code=404, detail=f"no such service {service_id}")
    if not await user_can_manage_agent(session, identity, service.agent_id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
    await session.delete(service)
    await session.commit()


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
    """Planned outage windows: scheduled, past and running.

    `active_only=true` narrows it to windows covering this moment, which is the set
    that is actually suppressing anything right now. Without `agent_id` you get the
    whole fleet's.
    """
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
    """Declare a planned outage window, so what happens in it is not a problem.

    A downtime covers one host (`agent_id`), optionally one `service_name` — omit it
    and the whole host is covered. During the window its services keep measuring and
    keep their real states; what changes is that they are left out of the problem list
    and the notification path.

    422 when the window makes no sense (an end at or before its start); 404 when there
    is no such host. A downtime is not retroactive: a window in the past changes
    nothing about the notifications that already went out, because rewriting whether
    an alarm "should have" fired would falsify the record.
    """
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
    """Remove a downtime window. If it is running, its host's services return to the
    problem list immediately — with their current states, not the states they had when
    the window opened."""
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
    # Site (subnet) scope — set iff scope_type='site' (mirrors ConfigPolicy.site_id).
    scope_site_id: UUID | None = None
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
    # Checkmk MATCH conditions (services/rule_conditions): host_tags / labels /
    # os / folder / host+service name. Distinct from extra_conditions (which are
    # threshold logic); empty = applies wherever the scope reaches.
    conditions: dict = {}


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
    scope_site_id: UUID | None = None
    # Every OU this policy applies to: the primary scope_ou_id plus any
    # additional OUs linked via check_rule_ou_links (one policy → many OUs).
    # Populated by list_check_rules; empty on the bare from_model path.
    # A3: this rule's version. Send it back in If-Match on PUT and a concurrent edit becomes
    # a 412 instead of a silent overwrite — see api/etag.py. `ou_ids` is excluded from the
    # hash by being populated only on the list path; it is not part of the row itself.
    version: str = ""
    ou_ids: list[UUID] = []
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
    conditions: dict = {}
    # Provenance. A rule is either authored here (both None) or generated by a Check
    # template's link to a host group (both set). PUT/PATCH/DELETE already refuse the
    # generated ones with 409 "edit the template instead" — but until now the response
    # did not say which rules those are, so a client could neither name the origin nor
    # disable the controls, and the refusal arrived as a surprise. Exposing it is what
    # lets the UI grey the row out and link to the template that owns it.
    # Excluded from the version hash (see api/etag.py `_VOLATILE`): server-assigned,
    # not editable content.
    template_id: UUID | None = None
    source_template_rule_id: UUID | None = None

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
            scope_site_id=r.scope_site_id,
            ou_ids=[r.scope_ou_id] if r.scope_ou_id is not None else [],
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
            conditions=r.conditions or {},
            template_id=r.template_id,
            source_template_rule_id=r.source_template_rule_id,
        )

    def with_version(self) -> "CheckRuleOut":
        self.version = compute_version(self)
        return self


def _validate_scope(scope_type: str, scope_value: str | None, scope_ou_id: UUID | None = None,
                    scope_site_id: UUID | None = None) -> None:
    if scope_type not in ("global", "group", "host", "ou", "site"):
        raise HTTPException(status_code=422, detail="scope_type must be one of global|group|host|ou|site")
    if scope_type == "ou":
        if scope_ou_id is None:
            raise HTTPException(status_code=422, detail="scope_ou_id is required when scope_type is 'ou'")
        if scope_value is not None or scope_site_id is not None:
            raise HTTPException(status_code=422, detail="only scope_ou_id may be set when scope_type is 'ou'")
        return
    if scope_type == "site":
        if scope_site_id is None:
            raise HTTPException(status_code=422, detail="scope_site_id is required when scope_type is 'site'")
        if scope_value is not None or scope_ou_id is not None:
            raise HTTPException(status_code=422, detail="only scope_site_id may be set when scope_type is 'site'")
        return
    if scope_ou_id is not None:
        raise HTTPException(status_code=422, detail="scope_ou_id is only valid when scope_type is 'ou'")
    if scope_site_id is not None:
        raise HTTPException(status_code=422, detail="scope_site_id is only valid when scope_type is 'site'")
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
    """Every check policy: which check is assigned where, with which parameters.

    A rule is the *intension* — the declaration "hosts in this scope run this check
    with these thresholds". The service states it produces are the extension. Keep the
    two apart when reading this: a rule can exist while no host matches it, and that
    is not an error.

    One rule can be linked to several OUs; both its primary scope and its additional
    OU links are folded into `ou_ids` here, deduplicated, so a caller does not have to
    join two tables to see a rule's real reach. For which rule actually *wins* on a
    given host — the precedence global < group < OU < site < host, with the reason —
    ask `GET /api/v1/agents/{agent_id}/effective-thresholds` instead.
    """
    rules = (await session.scalars(select(CheckRule).order_by(CheckRule.created_at.desc()))).all()
    # One policy can link to many OUs (check_rule_ou_links) — fold each rule's
    # additional OUs into ou_ids alongside its primary scope_ou_id.
    extra: dict[UUID, list[UUID]] = {}
    for link in (await session.scalars(select(CheckRuleOuLink))).all():
        extra.setdefault(link.rule_id, []).append(link.ou_id)
    out = []
    for r in rules:
        o = CheckRuleOut.from_model(r).with_version()
        merged = list(dict.fromkeys(o.ou_ids + extra.get(r.id, [])))  # dedup, preserve order
        o.ou_ids = merged
        out.append(o)
    return out


@router.post("/api/v1/check-rules", response_model=CheckRuleOut)
async def create_check_rule(
    body: CheckRuleIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> CheckRuleOut:
    """Assign a check to a scope with its parameters.

    The scope is what makes this a policy rather than a per-host setting: global, a
    host group, an OU, a site or a single host. Overlapping rules are legitimate and
    resolved by precedence (global < group < OU < site < host) rather than rejected —
    a narrower scope is how an exception is expressed.

    The parameters are validated against the check's own declared options, so a rule
    cannot carry a parameter the check would refuse. Nothing runs on a host until the
    assignment reaches it on the next cycle; the check is pushed to the agent and, if
    the agent rejects it, the resulting service says so rather than reporting a stale
    result.
    """
    if body.comparison not in ("gt", "lt", "ge", "le", "eq", "ne"):
        raise HTTPException(status_code=422, detail="comparison must be one of gt|lt|ge|le|eq|ne")
    _validate_scope(body.scope_type, body.scope_value, body.scope_ou_id, body.scope_site_id)
    _validate_composite(body)
    if body.scope_ou_id is not None and await session.get(OUNode, body.scope_ou_id) is None:
        raise HTTPException(status_code=422, detail=f"no such OU {body.scope_ou_id}")
    if body.scope_site_id is not None and await session.get(Site, body.scope_site_id) is None:
        raise HTTPException(status_code=422, detail=f"no such site {body.scope_site_id}")

    rule = CheckRule(
        service_name=body.service_name,
        metric=body.metric,
        comparison=body.comparison,
        warn_threshold=body.warn_threshold,
        crit_threshold=body.crit_threshold,
        scope_type=body.scope_type,
        scope_value=body.scope_value,
        scope_ou_id=body.scope_ou_id,
        scope_site_id=body.scope_site_id,
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
        conditions=body.conditions or {},
    )
    session.add(rule)
    await _enqueue_rule_change(session)
    await session.commit()
    return CheckRuleOut.from_model(rule).with_version()


@router.put("/api/v1/check-rules/{rule_id}", response_model=CheckRuleOut)
async def update_check_rule(
    rule_id: UUID,
    body: CheckRuleIn,
    request: Request,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> CheckRuleOut:
    """Replace a check policy wholesale.

    Every field is taken from the body, so a field you omit is *cleared*, not kept —
    use PATCH when you mean to change one thing.

    Send `If-Match` with the `version` from a previous read: a stale version is refused
    with **412**, so two editors cannot silently overwrite each other. Omitting the
    header is allowed and skips the check — the guarantee is for clients that send it.
    """
    rule = await session.get(CheckRule, rule_id)
    if rule is None:
        raise HTTPException(status_code=404, detail=f"no such check rule {rule_id}")
    # A3: refuse the write if the caller's copy is stale.
    check_if_match(request, CheckRuleOut.from_model(rule).with_version().version)
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
    _validate_scope(body.scope_type, body.scope_value, body.scope_ou_id, body.scope_site_id)
    _validate_composite(body)
    if body.scope_ou_id is not None and await session.get(OUNode, body.scope_ou_id) is None:
        raise HTTPException(status_code=422, detail=f"no such OU {body.scope_ou_id}")
    if body.scope_site_id is not None and await session.get(Site, body.scope_site_id) is None:
        raise HTTPException(status_code=422, detail=f"no such site {body.scope_site_id}")

    rule.service_name = body.service_name
    rule.metric = body.metric
    rule.comparison = body.comparison
    rule.warn_threshold = body.warn_threshold
    rule.crit_threshold = body.crit_threshold
    rule.scope_type = body.scope_type
    rule.scope_value = body.scope_value
    rule.scope_site_id = body.scope_site_id
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
    rule.conditions = body.conditions or {}
    await _enqueue_rule_change(session)
    await session.commit()
    return CheckRuleOut.from_model(rule).with_version()


class CheckRulePatch(BaseModel):
    """Partial GPO-flag update (Block L3a) — powers the tree console's
    Enforced / Enabled context-menu toggles without resending the whole rule.
    `scope_ou_id` re-scopes the rule to another OU (the palette drag-to-link
    gesture, Block L3e)."""

    enforced: bool | None = None
    enabled: bool | None = None
    link_order: int | None = None
    scope_ou_id: UUID | None = None


@router.patch("/api/v1/check-rules/{rule_id}", response_model=CheckRuleOut)
async def patch_check_rule(
    rule_id: UUID,
    body: CheckRulePatch,
    request: Request,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> CheckRuleOut:
    """Change individual fields of a check policy; anything you omit stays as it is.

    Use this rather than PUT for a partial edit — PUT clears what it does not carry.

    Send `If-Match` with the `version` from a previous read and a stale version is refused with
    **412**, exactly as on PUT. Omit the header and the write goes through: the guarantee is that a
    client which sends it cannot clobber a concurrent change, not that every client must.

    This guard was missing here while PUT had it, which is the wrong way round — a partial edit is
    where a lost update is most likely, because two people changing *different* fields of one rule
    both believe they are safe.
    """
    rule = await session.get(CheckRule, rule_id)
    if rule is None:
        raise HTTPException(status_code=404, detail=f"no such check rule {rule_id}")
    check_if_match(request, CheckRuleOut.from_model(rule).with_version().version)
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
    if body.scope_ou_id is not None:
        # Re-scope to another OU (drag-link). scope_type follows so the rule
        # actually resolves against the OU tree.
        if await session.get(OUNode, body.scope_ou_id) is None:
            raise HTTPException(status_code=422, detail=f"no such OU {body.scope_ou_id}")
        rule.scope_ou_id = body.scope_ou_id
        rule.scope_type = "ou"
    await _enqueue_rule_change(session)
    await session.commit()
    return CheckRuleOut.from_model(rule).with_version()


class OuLinkIn(BaseModel):
    ou_id: UUID


@router.post("/api/v1/check-rules/{rule_id}/ou-links", response_model=CheckRuleOut)
async def add_check_rule_ou_link(
    rule_id: UUID,
    body: OuLinkIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> CheckRuleOut:
    """Link a threshold policy to ANOTHER OU — one policy applies to many OUs
    (GPO-style multi-link) instead of being duplicated per OU. If the rule has
    no OU yet, the first linked OU becomes its primary scope; otherwise it's
    recorded in check_rule_ou_links. Idempotent."""
    rule = await session.get(CheckRule, rule_id)
    if rule is None:
        raise HTTPException(status_code=404, detail=f"no such check rule {rule_id}")
    if rule.template_id is not None:
        raise HTTPException(status_code=409, detail=f"check rule {rule_id} is managed by a template — edit the template instead")
    if await session.get(OUNode, body.ou_id) is None:
        raise HTTPException(status_code=422, detail=f"no such OU {body.ou_id}")

    # Already the primary OU, or already linked → no-op (idempotent).
    if rule.scope_ou_id == body.ou_id:
        await session.commit()
        return CheckRuleOut.from_model(rule).with_version()
    existing = await session.scalar(
        select(CheckRuleOuLink).where(CheckRuleOuLink.rule_id == rule_id, CheckRuleOuLink.ou_id == body.ou_id)
    )
    if existing is None:
        if rule.scope_ou_id is None:
            # First OU for this policy → make it the primary scope.
            rule.scope_type = "ou"
            rule.scope_value = None
            rule.scope_ou_id = body.ou_id
        else:
            session.add(CheckRuleOuLink(rule_id=rule_id, ou_id=body.ou_id))
    await _enqueue_rule_change(session)
    await session.commit()
    await session.refresh(rule)
    links = (await session.scalars(select(CheckRuleOuLink).where(CheckRuleOuLink.rule_id == rule_id))).all()
    out = CheckRuleOut.from_model(rule).with_version()
    out.ou_ids = list(dict.fromkeys(out.ou_ids + [l.ou_id for l in links]))
    return out


@router.delete("/api/v1/check-rules/{rule_id}/ou-links/{ou_id}", response_model=CheckRuleOut)
async def remove_check_rule_ou_link(
    rule_id: UUID,
    ou_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> CheckRuleOut:
    """Unlink a threshold policy from one OU. Removing the primary OU promotes
    another linked OU to primary (so an ou-scoped rule always keeps ≥1 OU);
    removing the last remaining OU is refused — delete the rule instead."""
    rule = await session.get(CheckRule, rule_id)
    if rule is None:
        raise HTTPException(status_code=404, detail=f"no such check rule {rule_id}")
    if rule.template_id is not None:
        raise HTTPException(status_code=409, detail=f"check rule {rule_id} is managed by a template — edit the template instead")

    if rule.scope_ou_id == ou_id:
        # Promote a linked OU to primary, or refuse if this is the only OU.
        promote = await session.scalar(
            select(CheckRuleOuLink).where(CheckRuleOuLink.rule_id == rule_id).limit(1)
        )
        if promote is None:
            raise HTTPException(status_code=409, detail="cannot unlink the only OU — delete the rule instead")
        rule.scope_ou_id = promote.ou_id
        await session.delete(promote)
    else:
        link = await session.scalar(
            select(CheckRuleOuLink).where(CheckRuleOuLink.rule_id == rule_id, CheckRuleOuLink.ou_id == ou_id)
        )
        if link is None:
            raise HTTPException(status_code=404, detail=f"rule {rule_id} is not linked to OU {ou_id}")
        await session.delete(link)
    await _enqueue_rule_change(session)
    await session.commit()
    await session.refresh(rule)
    links = (await session.scalars(select(CheckRuleOuLink).where(CheckRuleOuLink.rule_id == rule_id))).all()
    out = CheckRuleOut.from_model(rule).with_version()
    out.ou_ids = list(dict.fromkeys(out.ou_ids + [l.ou_id for l in links]))
    return out


@router.delete("/api/v1/check-rules/{rule_id}", status_code=204)
async def delete_check_rule(
    rule_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> None:
    """Remove a check policy.

    The check stops being assigned through this rule; hosts that matched it lose the
    service on the next cycle. Hosts that also match another rule keep it, with that
    rule's parameters — which may differ, so a delete can change thresholds rather
    than remove a check.
    """
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
    """The fleet in numbers: hosts by state, services by state, what needs attention.

    The overview's top row, and read the axes carefully because they differ:

    - **Hosts are counted by enrollment state**, not by health — pending, enrolled and
      the rest. A host's health is a rollup of its services, and this number is not
      that.
    - **Services are counted by monitoring state** across the four: OK, WARN, CRIT,
      UNKNOWN.
    - **Open problems** is the narrower number an operator acts on: non-OK, *not*
      acknowledged and *not* under a downtime. It is deliberately smaller than
      WARN + CRIT + UNKNOWN, and the difference is the work someone has already taken.

    Every value is a count of rows that exist right now — not a rate, not an average.
    """
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
    agent_version: str
    last_seen_at: datetime | None
    state_rollup: str
    cpu_load: float | None
    mem_used_pct: float | None
    disk_used_pct_max: float | None
    service_counts: dict[str, int]


@router.get("/api/v1/fleet/hosts", response_model=list[FleetHostOut])
async def fleet_hosts_route(
    agent_id: UUID | None = Query(None, description="Return only this host's row"),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[FleetHostOut]:
    """The host-overview table's data source (see docs/plan.md's
    monitoring-cockpit ergänzung Block F2/F3): one row per host — every
    directly enrolled agent and every satellite discovered behind a
    proxy — with real CPU/memory/disk values and a CheckMK-style state
    rollup, in a single call instead of a per-host metrics fan-out."""
    hosts = await fleet_hosts(session, agent_id)
    return [
        FleetHostOut(
            id=h.id,
            name=h.name,
            parent_agent_id=h.parent_agent_id,
            parent_name=h.parent_name,
            mode=h.mode,
            enrollment_state=h.enrollment_state,
            agent_version=h.agent_version,
            last_seen_at=h.last_seen_at,
            state_rollup=h.state_rollup,
            cpu_load=h.cpu_load,
            mem_used_pct=h.mem_used_pct,
            disk_used_pct_max=h.disk_used_pct_max,
            service_counts=h.service_counts,
        )
        for h in hosts
    ]
