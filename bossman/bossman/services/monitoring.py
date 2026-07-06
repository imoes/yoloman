"""CheckMK-style monitoring core: threshold rules (with CheckMK's own
rule-precedence model — host overrides group overrides global) evaluated
against the metrics the poller already pulls, materialized as per-host
Services with a state (OK/WARN/CRIT/UNKNOWN) — the concrete answer to
"the host topology doesn't look like a real monitoring system" (see
docs/plan.md's monitoring Block E2). A Service in a non-OK state that
isn't acknowledged is an active "problem" (see api/monitoring.py's
GET /api/v1/problems, which also excludes services under an active
Downtime — that filter lives there, not here, since it's a query-time
concern, not part of state computation).

Framework-free (no FastAPI import), like services/plan_engine.py and
services/poller.py, so it's reachable from the poller's background loop,
the REST API, MCP tools, and tests without duplicating logic.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from uuid import UUID

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, CheckRule, Downtime, Metric, Service, ServiceStateHistory

_COMPARISONS = {
    "gt": lambda value, threshold: value > threshold,
    "lt": lambda value, threshold: value < threshold,
    "ge": lambda value, threshold: value >= threshold,
    "le": lambda value, threshold: value <= threshold,
    "eq": lambda value, threshold: value == threshold,
    "ne": lambda value, threshold: value != threshold,
}

# host > group > global — the exact precedence the user asked for
# ("Regeln für Gruppen ... die von Host-Regeln übersteuert werden
# können"), mirroring CheckMK's own rule-set editor.
_SCOPE_PRECEDENCE = {"host": 0, "group": 1, "global": 2}


def resolve_effective_rule(
    rules: list[CheckRule], host_name: str, host_groups: list[str], metric: str
) -> CheckRule | None:
    """Picks the single rule that governs `metric` on this host, out of
    every rule that could apply. Only enabled rules for this exact metric
    are considered; among those, the most specific scope wins (host over
    group over global); ties at the same specificity (e.g. two group
    rules whose group both match) are broken by most-recently-created.
    Returns None if nothing matches — the caller should leave that metric
    unevaluated rather than inventing a default."""

    def _matches(rule: CheckRule) -> bool:
        if rule.scope_type == "global":
            return True
        if rule.scope_type == "group":
            return rule.scope_value in host_groups
        if rule.scope_type == "host":
            return rule.scope_value == host_name
        return False

    matching = [r for r in rules if r.enabled and r.metric == metric and _matches(r)]
    if not matching:
        return None

    # Stable sort twice: newest-first, then by scope specificity — a
    # stable sort preserves the newest-first order among equal-precedence
    # rules, giving "most specific, and among ties, most recent" overall.
    matching.sort(key=lambda r: r.created_at, reverse=True)
    matching.sort(key=lambda r: _SCOPE_PRECEDENCE[r.scope_type])
    return matching[0]


def compute_state(comparison: str, value: float | None, warn: float | None, crit: float | None) -> tuple[str, str]:
    """Nagios-style threshold evaluation: CRIT is checked before WARN (a
    value that would trip both is CRIT, not WARN); UNKNOWN when there's no
    metric value at all (a stale/never-polled host), not silently OK."""
    if value is None:
        return "UNKNOWN", "no recent metric value"

    cmp_fn = _COMPARISONS[comparison]
    if crit is not None and cmp_fn(value, crit):
        return "CRIT", f"value {value!r} {comparison} crit threshold {crit!r}"
    if warn is not None and cmp_fn(value, warn):
        return "WARN", f"value {value!r} {comparison} warn threshold {warn!r}"
    return "OK", f"value {value!r} within thresholds"


async def evaluate_host(session: AsyncSession, agent: Agent) -> list[Service]:
    """Re-evaluates every check_rules-derived service for one agent
    against its most recently polled metric values, upserting `services`
    and recording a `service_state_history` row on each state change.
    Meant to be called right after the poller writes fresh metrics for
    this agent (same session, not yet committed — evaluate_host reads its
    own just-written rows via that same, still-open transaction). Does
    not commit; the caller owns the transaction boundary."""
    rules = (await session.scalars(select(CheckRule).where(CheckRule.enabled == True))).all()  # noqa: E712
    metrics_needed = sorted({r.metric for r in rules})
    if not metrics_needed:
        return []

    now = datetime.now(timezone.utc)
    updated: list[Service] = []

    for metric in metrics_needed:
        rule = resolve_effective_rule(list(rules), agent.name, agent.groups, metric)
        if rule is None:
            continue

        latest = await session.scalar(
            select(Metric)
            .where(Metric.agent_id == agent.id, Metric.metric == metric)
            .order_by(Metric.time.desc())
            .limit(1)
        )
        value = latest.value if latest is not None else None
        state, output = compute_state(rule.comparison, value, rule.warn_threshold, rule.crit_threshold)

        existing = await session.scalar(
            select(Service).where(Service.agent_id == agent.id, Service.name == rule.service_name)
        )
        state_changed = existing is None or existing.state != state

        if existing is None:
            existing = Service(
                agent_id=agent.id,
                name=rule.service_name,
                metric=metric,
                state=state,
                value=value,
                output=output,
                rule_id=rule.id,
                last_state_change=now,
                last_checked=now,
            )
            session.add(existing)
        else:
            existing.metric = metric
            existing.state = state
            existing.value = value
            existing.output = output
            existing.rule_id = rule.id
            existing.last_checked = now
            if state_changed:
                existing.last_state_change = now
                # An acknowledgement is tied to the specific problem
                # occurrence it was made for (CheckMK's own model) — any
                # state change, in either direction, means this is a new
                # occurrence, so a stale ack must not silently suppress it.
                existing.acknowledged = False
                existing.ack_comment = None
                existing.ack_by = None

        if state_changed:
            session.add(
                ServiceStateHistory(time=now, agent_id=agent.id, service_name=rule.service_name, state=state, value=value)
            )
        updated.append(existing)

    await session.flush()
    return updated


# Maps the Go agent's Nagios-style checks.Status strings (see
# internal/checks.Status: OK/WARNING/CRITICAL/UNKNOWN) onto this project's
# own Service.state vocabulary (OK/WARN/CRIT/UNKNOWN, ck_services_state) —
# the two were named independently and don't line up character-for-character.
_AGENT_CHECK_STATUS = {"OK": "OK", "WARNING": "WARN", "CRITICAL": "CRIT", "UNKNOWN": "UNKNOWN"}


async def ingest_agent_checks(session: AsyncSession, agent: Agent, agent_checks: list[dict]) -> list[Service]:
    """Upserts one Service row per agent-reported check (see
    GET /api/v1/hosts/overview's `checks` field, docs/plan.md's
    monitoring-cockpit ergänzung Block F1/F2) — the agent-native
    counterpart to evaluate_host's Bossman-rule-derived services. Both
    populate the same `services` table; `rule_id IS NULL` is what
    distinguishes an agent-reported check from a Bossman check_rule
    result, so a caller never needs a separate "source" column to tell
    them apart. Mirrors evaluate_host's own upsert-with-history shape
    (state-change detection, service_state_history, ack-clearing on state
    change) so the two paths behave identically from a problems/ack/
    downtime point of view. Does not commit; the caller owns the
    transaction boundary."""
    now = datetime.now(timezone.utc)
    updated: list[Service] = []

    for chk in agent_checks:
        name = chk.get("name")
        if not name:
            continue
        state = _AGENT_CHECK_STATUS.get(chk.get("status", ""), "UNKNOWN")
        output = chk.get("message") or ""
        value = None
        for pd in chk.get("perfdata") or []:
            try:
                value = float(pd.get("value", ""))
                break
            except (TypeError, ValueError):
                continue

        existing = await session.scalar(select(Service).where(Service.agent_id == agent.id, Service.name == name))
        state_changed = existing is None or existing.state != state

        if existing is None:
            existing = Service(
                agent_id=agent.id,
                name=name,
                metric="",
                state=state,
                value=value,
                output=output,
                rule_id=None,
                last_state_change=now,
                last_checked=now,
            )
            session.add(existing)
        else:
            existing.state = state
            existing.value = value
            existing.output = output
            existing.last_checked = now
            if state_changed:
                existing.last_state_change = now
                existing.acknowledged = False
                existing.ack_comment = None
                existing.ack_by = None

        if state_changed:
            session.add(ServiceStateHistory(time=now, agent_id=agent.id, service_name=name, state=state, value=value))
        updated.append(existing)

    await session.flush()
    return updated


# ---------------------------------------------------------------------------
# Shared query/mutation layer for the "unbehandelte Probleme" surface —
# used by both api/monitoring.py (REST) and mcp/server.py (the MCP-native
# admin entry point this whole project is built around), so the
# in-downtime/filtering logic lives exactly once.


@dataclass
class ServiceView:
    """One Service plus the two things that don't live on the row itself:
    its host's name (a join) and whether it's currently covered by an
    active Downtime (a point-in-time computation, not stored state)."""

    service: Service
    agent_name: str
    in_downtime: bool


async def is_in_downtime(session: AsyncSession, agent_id: UUID, service_name: str, now: datetime) -> bool:
    """Whether some Downtime row covers this exact (agent_id,
    service_name) right now. `Downtime.service_name IS NULL` means a
    whole-host downtime, which covers every service on that host."""
    exists_clause = (
        select(Downtime.id)
        .where(
            Downtime.agent_id == agent_id,
            or_(Downtime.service_name.is_(None), Downtime.service_name == service_name),
            Downtime.starts_at <= now,
            Downtime.ends_at >= now,
        )
        .exists()
    )
    return bool(await session.scalar(select(exists_clause)))


async def _to_view(session: AsyncSession, service: Service, agent_name: str, now: datetime) -> ServiceView:
    in_downtime = await is_in_downtime(session, service.agent_id, service.name, now)
    return ServiceView(service=service, agent_name=agent_name, in_downtime=in_downtime)


async def to_view(session: AsyncSession, service: Service) -> ServiceView:
    """Public single-service wrapper around _to_view for callers (REST
    routes after a mutation) that only have the Service itself, not an
    already-joined agent_name — looks the Agent up by service.agent_id."""
    agent = await session.get(Agent, service.agent_id)
    return await _to_view(session, service, agent.name, datetime.now(timezone.utc))


async def query_problems(
    session: AsyncSession,
    *,
    state: str | None = None,
    host: str | None = None,
    acknowledged: bool | None = None,
    include_downtime: bool = False,
) -> list[ServiceView]:
    """Every non-OK service, most recently changed first — the "unbehandelte
    Probleme" view every real monitoring system leads with. Excludes
    services currently under an active Downtime unless include_downtime is
    set, since a downtime means "we already know, don't page anyone"."""
    now = datetime.now(timezone.utc)
    stmt = select(Service, Agent.name).join(Agent, Agent.id == Service.agent_id).where(Service.state != "OK")
    if state is not None:
        stmt = stmt.where(Service.state == state)
    if host is not None:
        stmt = stmt.where(Agent.name == host)
    if acknowledged is not None:
        stmt = stmt.where(Service.acknowledged == acknowledged)
    stmt = stmt.order_by(Service.last_state_change.desc())

    rows = (await session.execute(stmt)).all()
    results = []
    for service, agent_name in rows:
        view = await _to_view(session, service, agent_name, now)
        if not include_downtime and view.in_downtime:
            continue
        results.append(view)
    return results


async def service_state_history(
    session: AsyncSession, agent_id: UUID, service_name: str, limit: int = 200
) -> list[ServiceStateHistory]:
    """One service's state timeline, newest first — the "Zustands-Historie"
    half of the Übersicht→Host→Service→Graph drill-down (the metric value
    itself is served by the existing agents/{id}/metrics endpoint;  this is
    just the derived OK/WARN/CRIT/UNKNOWN state over time)."""
    rows = (
        await session.scalars(
            select(ServiceStateHistory)
            .where(ServiceStateHistory.agent_id == agent_id, ServiceStateHistory.service_name == service_name)
            .order_by(ServiceStateHistory.time.desc())
            .limit(limit)
        )
    ).all()
    return list(rows)


async def query_agent_services(session: AsyncSession, agent_id: UUID) -> list[ServiceView] | None:
    """Every service for one host, by id. Returns None (not an empty list)
    if the agent itself doesn't exist, so callers can tell "no services
    yet" apart from "no such host"."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        return None
    now = datetime.now(timezone.utc)
    services = (await session.scalars(select(Service).where(Service.agent_id == agent_id).order_by(Service.name))).all()
    return [await _to_view(session, s, agent.name, now) for s in services]


async def acknowledge_service(session: AsyncSession, service_id: UUID, comment: str, ack_by: str) -> Service | None:
    service = await session.get(Service, service_id)
    if service is None:
        return None
    service.acknowledged = True
    service.ack_comment = comment
    service.ack_by = ack_by
    await session.commit()
    return service


async def unacknowledge_service(session: AsyncSession, service_id: UUID) -> Service | None:
    service = await session.get(Service, service_id)
    if service is None:
        return None
    service.acknowledged = False
    service.ack_comment = None
    service.ack_by = None
    await session.commit()
    return service


async def create_downtime(
    session: AsyncSession,
    *,
    agent_id: UUID,
    service_name: str | None,
    starts_at: datetime,
    ends_at: datetime,
    comment: str,
    created_by: str | None,
) -> Downtime | None:
    """Returns None if agent_id doesn't exist; raises ValueError if
    ends_at <= starts_at — a real validation error, not a "not found"."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        return None
    if ends_at <= starts_at:
        raise ValueError("ends_at must be after starts_at")

    downtime = Downtime(
        agent_id=agent_id,
        service_name=service_name,
        starts_at=starts_at,
        ends_at=ends_at,
        comment=comment,
        created_by=created_by,
    )
    session.add(downtime)
    await session.commit()
    return downtime


@dataclass
class FleetSummary:
    hosts_total: int
    hosts_by_enrollment: dict[str, int]
    services_by_state: dict[str, int]
    open_problems: int


async def fleet_summary(session: AsyncSession) -> FleetSummary:
    """Counters for the fleet overview page: hosts by enrollment state,
    services by monitoring state, and how many are genuinely open problems
    (non-OK, unacknowledged, not in downtime) — the number that should
    actually draw a human's attention."""
    agents = (await session.scalars(select(Agent))).all()
    hosts_by_enrollment: dict[str, int] = {}
    for a in agents:
        hosts_by_enrollment[a.enrollment_state] = hosts_by_enrollment.get(a.enrollment_state, 0) + 1

    now = datetime.now(timezone.utc)
    services = (await session.scalars(select(Service))).all()
    services_by_state: dict[str, int] = {"OK": 0, "WARN": 0, "CRIT": 0, "UNKNOWN": 0}
    open_problems = 0
    for s in services:
        services_by_state[s.state] = services_by_state.get(s.state, 0) + 1
        if s.state != "OK" and not s.acknowledged:
            if not await is_in_downtime(session, s.agent_id, s.name, now):
                open_problems += 1

    return FleetSummary(
        hosts_total=len(agents),
        hosts_by_enrollment=hosts_by_enrollment,
        services_by_state=services_by_state,
        open_problems=open_problems,
    )


# Worst-wins precedence for a host's overall state rollup — CheckMK's own
# convention: a single CRIT service makes the whole host read CRIT on the
# fleet overview, even if every other service is OK.
_STATE_SEVERITY = {"OK": 0, "WARN": 1, "UNKNOWN": 2, "CRIT": 3}


@dataclass
class FleetHostSummary:
    """One row of the fleet host-overview table (see docs/plan.md's
    monitoring-cockpit ergänzung Block F2/F3) — a CheckMK/Zabbix-style
    "latest data" snapshot per host, real values only (no per-metric
    drill-down needed just to see whether a host is healthy)."""

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


async def _latest_metric_by_agent(session: AsyncSession, metric_name: str) -> dict[UUID, float]:
    """The single latest value of a non-mount-labeled metric (e.g.
    cpu_load1, mem_used_pct) per agent, via Postgres's DISTINCT ON —
    one query regardless of fleet size, not a per-host fan-out."""
    stmt = (
        select(Metric.agent_id, Metric.value)
        .distinct(Metric.agent_id)
        .where(Metric.metric == metric_name)
        .order_by(Metric.agent_id, Metric.time.desc())
    )
    rows = (await session.execute(stmt)).all()
    return {r.agent_id: r.value for r in rows}


async def _latest_disk_used_pct_max(session: AsyncSession) -> dict[UUID, float]:
    """The worst (highest) latest disk_used_pct across every mount an
    agent reports — a host with one nearly-full disk should read as
    "nearly full" on the fleet overview, not be diluted by its other,
    mostly-empty mounts."""
    mount_label = Metric.labels["mount"].astext
    stmt = (
        select(Metric.agent_id, mount_label.label("mount"), Metric.value)
        .distinct(Metric.agent_id, mount_label)
        .where(Metric.metric == "disk_used_pct")
        .order_by(Metric.agent_id, mount_label, Metric.time.desc())
    )
    rows = (await session.execute(stmt)).all()
    out: dict[UUID, float] = {}
    for r in rows:
        out[r.agent_id] = max(out.get(r.agent_id, r.value), r.value)
    return out


async def fleet_hosts(session: AsyncSession) -> list[FleetHostSummary]:
    """One row per host — every directly enrolled agent *and* every
    satellite discovered via a proxy's own GET /api/v1/hosts/overview
    (services/poller.py's _find_or_create_satellite) — with a CheckMK-
    style worst-service-wins state rollup and the at-a-glance CPU/memory/
    disk values a real fleet cockpit needs. Exactly 5 queries total
    (agents, services, and 3 latest-metric lookups), never one per host:
    the concrete fix for "no bulk endpoint for a host-overview table"."""
    agents = (await session.scalars(select(Agent).order_by(Agent.name))).all()
    names_by_id = {a.id: a.name for a in agents}

    services = (await session.scalars(select(Service))).all()
    services_by_agent: dict[UUID, list[Service]] = {}
    for s in services:
        services_by_agent.setdefault(s.agent_id, []).append(s)

    cpu_by_agent = await _latest_metric_by_agent(session, "cpu_load1")
    mem_by_agent = await _latest_metric_by_agent(session, "mem_used_pct")
    disk_by_agent = await _latest_disk_used_pct_max(session)

    out = []
    for agent in agents:
        agent_services = services_by_agent.get(agent.id, [])
        counts = {"OK": 0, "WARN": 0, "CRIT": 0, "UNKNOWN": 0}
        worst = "OK"
        for s in agent_services:
            counts[s.state] = counts.get(s.state, 0) + 1
            if _STATE_SEVERITY.get(s.state, 0) > _STATE_SEVERITY.get(worst, 0):
                worst = s.state

        out.append(
            FleetHostSummary(
                id=agent.id,
                name=agent.name,
                parent_agent_id=agent.parent_agent_id,
                parent_name=names_by_id.get(agent.parent_agent_id) if agent.parent_agent_id else None,
                mode=agent.mode,
                enrollment_state=agent.enrollment_state,
                last_seen_at=agent.last_seen_at,
                state_rollup=worst,
                cpu_load=cpu_by_agent.get(agent.id),
                mem_used_pct=mem_by_agent.get(agent.id),
                disk_used_pct_max=disk_by_agent.get(agent.id),
                service_counts=counts,
            )
        )
    return out
