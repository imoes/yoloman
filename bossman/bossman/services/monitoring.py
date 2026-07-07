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
from datetime import datetime, timedelta, timezone
from uuid import UUID

from sqlalchemy import func, or_, select, update
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
    rules: list[CheckRule], host_name: str, host_groups: list[str], metric: str, label_value: str | None = None
) -> CheckRule | None:
    """Picks the single rule that governs `metric` (for one label series,
    e.g. a disk mount) on this host, out of every rule that could apply.
    Only enabled rules for this exact metric are considered; among those,
    the most specific label wins (a rule pinned to this label_value over a
    label-agnostic one — Block H6), then the most specific scope (host >
    group > global), then most-recently-created. A rule pinned to a
    *different* label_value is excluded. Returns None if nothing matches."""

    def _scope_matches(rule: CheckRule) -> bool:
        if rule.scope_type == "global":
            return True
        if rule.scope_type == "group":
            return rule.scope_value in host_groups
        if rule.scope_type == "host":
            return rule.scope_value == host_name
        return False

    def _label_matches(rule: CheckRule) -> bool:
        # A label-agnostic rule (label_value NULL) applies to every series;
        # a pinned rule only to its own label_value.
        return rule.label_value is None or rule.label_value == label_value

    matching = [r for r in rules if r.enabled and r.metric == metric and _scope_matches(r) and _label_matches(r)]
    if not matching:
        return None

    # Stable sorts, least-significant first: newest → scope → label. The
    # last sort dominates, so overall: label-specific beats label-agnostic,
    # then host beats group beats global, then newest breaks ties.
    matching.sort(key=lambda r: r.created_at, reverse=True)
    matching.sort(key=lambda r: _SCOPE_PRECEDENCE[r.scope_type])
    matching.sort(key=lambda r: 0 if r.label_value == label_value else 1)
    return matching[0]


# Consecutive non-OK checks before a state is promoted to hard (Block H7),
# when no per-rule max_attempts is set. CheckMK's own default is 3.
DEFAULT_MAX_ATTEMPTS = 3
# Flapping (Block H7): if a service changed state at least this many times
# within the look-back window, it's oscillating — flag it (and, later,
# suppress its notifications). A windowed transition count, not CheckMK's
# exact 21-result ratio, but the same intent and easy to reason about.
_FLAP_WINDOW = timedelta(minutes=30)
_FLAP_MIN_CHANGES = 5


class Transition:
    """The outcome of feeding one fresh raw state into a service's soft/hard
    state machine (Block H7): the resulting state_type/attempt, whether the
    raw state changed at all, and whether this is a *hard* change — the
    moment a problem becomes real (hard non-OK) or recovers (OK). Only hard
    changes append history / clear acks / (later) notify."""

    __slots__ = ("state", "state_type", "attempt", "raw_changed", "hard_changed")

    def __init__(self, state, state_type, attempt, raw_changed, hard_changed):
        self.state = state
        self.state_type = state_type
        self.attempt = attempt
        self.raw_changed = raw_changed
        self.hard_changed = hard_changed


def next_transition(
    prev_state: str | None, prev_type: str, prev_attempt: int, new_state: str, max_attempts: int
) -> Transition:
    """Pure soft/hard state-machine step. Recovery to OK is always an
    immediate hard state. A non-OK result starts soft at attempt 1 and only
    goes hard once it has recurred `max_attempts` times unchanged; any
    change to a *different* state restarts the soft count. With
    max_attempts <= 1 every result is immediately hard (debouncing off)."""
    raw_changed = prev_state is None or prev_state != new_state

    if new_state == "OK":
        state_type = "hard"
        attempt = 1
        # Record on first-ever observation (a baseline OK for availability),
        # or on recovery from a *hard* non-OK state. A soft problem that
        # never notified shouldn't emit a hard "recovered".
        hard_changed = prev_state is None or (prev_state != "OK" and prev_type == "hard")
        return Transition("OK", state_type, attempt, raw_changed, hard_changed)

    # non-OK
    if not raw_changed and prev_type == "soft" and prev_attempt < max_attempts:
        attempt = prev_attempt + 1
    elif not raw_changed:
        attempt = prev_attempt  # already hard, or max reached
    else:
        attempt = 1  # changed to a different (non-OK) state → restart soft

    state_type = "hard" if attempt >= max_attempts else "soft"
    # A hard change = the effective (hard) state now differs from the
    # previously effective hard state. The previous effective hard state is
    # prev_state only if it was itself hard (a soft blip never became
    # "effective"). This fires on problem onset (soft→hard or first-ever),
    # on escalation (hard WARN → hard CRIT), but not while a hard state
    # simply persists.
    prev_hard_state = prev_state if prev_type == "hard" else None
    hard_changed = state_type == "hard" and prev_hard_state != new_state
    return Transition(new_state, state_type, attempt, raw_changed, hard_changed)


async def update_flapping(session: AsyncSession, agent_id: UUID, service_name: str, now: datetime) -> bool:
    """Recomputes whether a service is flapping from its recent state-change
    history (Block H7). Returns the flag; caller stores it on the Service."""
    since = now - _FLAP_WINDOW
    changes = await session.scalar(
        select(func.count())
        .select_from(ServiceStateHistory)
        .where(
            ServiceStateHistory.agent_id == agent_id,
            ServiceStateHistory.service_name == service_name,
            ServiceStateHistory.time >= since,
        )
    )
    return (changes or 0) >= _FLAP_MIN_CHANGES


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
        # Latest value per distinct label series (DISTINCT ON labels): an
        # unlabeled metric yields one row; disk_used_pct yields one per
        # mount, so a single rule fans out to one service per mount
        # (Block H6). No labeled series at all → one None-labeled entry so
        # a rule still applies (e.g. a never-yet-sampled metric → UNKNOWN).
        latest_rows = (
            await session.scalars(
                select(Metric)
                .where(Metric.agent_id == agent.id, Metric.metric == metric)
                .order_by(Metric.labels, Metric.time.desc())
                .distinct(Metric.labels)
            )
        ).all()
        series: list[tuple[dict, float | None]] = [(row.labels or {}, row.value) for row in latest_rows] or [({}, None)]

        for labels, value in series:
            mount = labels.get("mount")
            rule = resolve_effective_rule(list(rules), agent.name, agent.groups, metric, mount)
            if rule is None:
                continue

            state, output = compute_state(rule.comparison, value, rule.warn_threshold, rule.crit_threshold)
            # Fan-out naming: a labeled series gets "<service_name> <mount>"
            # so a "Disk" rule reproduces the agent's own "Disk /var" names
            # (and thus overrides them); unlabeled metrics keep the plain name.
            svc_name = f"{rule.service_name} {mount}" if mount else rule.service_name

            max_attempts = rule.max_attempts or DEFAULT_MAX_ATTEMPTS
            svc = await _upsert_service_state(
                session, agent.id, svc_name, state, value, output, now, max_attempts,
                metric=metric, rule_id=rule.id, agent_name=agent.name,
            )
            updated.append(svc)

    await session.flush()
    return updated


async def _upsert_service_state(
    session: AsyncSession,
    agent_id: UUID,
    name: str,
    new_state: str,
    value: float | None,
    output: str,
    now: datetime,
    max_attempts: int,
    *,
    metric: str,
    rule_id: UUID | None,
    agent_name: str = "",
) -> Service:
    """The one place a Service row is created/updated from a fresh check
    result — shared by the rule evaluator and the agent-check ingester so
    soft/hard debouncing (Block H7), flapping, history and ack-clearing
    behave identically on both paths. History is appended and the ack is
    cleared only on a *hard* change (a real problem onset/recovery), not on
    every soft flicker, so a debounced blip neither pages nor churns the
    timeline."""
    existing = await session.scalar(select(Service).where(Service.agent_id == agent_id, Service.name == name))
    prev_state = existing.state if existing else None
    # "" (not "hard") for a brand-new service, so a first-ever immediately-
    # hard non-OK result still counts as a hard change (prev_type != "hard").
    prev_type = existing.state_type if existing else ""
    prev_attempt = existing.attempt if existing else 0
    t = next_transition(prev_state, prev_type, prev_attempt, new_state, max_attempts)

    if existing is None:
        existing = Service(
            agent_id=agent_id,
            name=name,
            metric=metric,
            state=t.state,
            value=value,
            output=output,
            rule_id=rule_id,
            state_type=t.state_type,
            attempt=t.attempt,
            max_attempts=max_attempts,
            last_state_change=now,
            last_checked=now,
        )
        session.add(existing)
    else:
        existing.metric = metric
        existing.value = value
        existing.output = output
        existing.rule_id = rule_id
        existing.state = t.state
        existing.state_type = t.state_type
        existing.attempt = t.attempt
        existing.max_attempts = max_attempts
        existing.last_checked = now
        if t.raw_changed:
            existing.last_state_change = now
        if t.hard_changed:
            # A confirmed (hard) problem onset or recovery is a new
            # occurrence — a stale ack must not carry over (CheckMK's model).
            existing.acknowledged = False
            existing.ack_comment = None
            existing.ack_by = None
            existing.ack_expires_at = None

    # History records confirmed (hard) changes — the timeline availability
    # (H9) and flapping both read, so soft flickers stay out of both.
    if t.hard_changed:
        session.add(ServiceStateHistory(time=now, agent_id=agent_id, service_name=name, state=t.state, value=value))
        await session.flush()  # so update_flapping counts this change too

    existing.is_flapping = await update_flapping(session, agent_id, name, now)

    # Stamp a transient notification intent for the poller to dispatch after
    # commit (Block H8): only confirmed hard changes notify. Not persisted.
    if t.hard_changed:
        existing._notify_event = "recovery" if t.state == "OK" else "problem"
    else:
        existing._notify_event = None
    existing._notify_agent_name = agent_name
    return existing


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
        # Rule authority (Block H6): once a Bossman check_rule owns a service
        # of this name (rule_id set — e.g. the seeded "Memory"/"Disk /var"
        # defaults), the rule grades it with its configurable, host-
        # overridable thresholds. Ignore the agent's built-in reading so the
        # two don't fight over the same row every poll.
        if existing is not None and existing.rule_id is not None:
            continue

        svc = await _upsert_service_state(
            session, agent.id, name, state, value, output, now, DEFAULT_MAX_ATTEMPTS,
            metric="", rule_id=None, agent_name=agent.name,
        )
        updated.append(svc)

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
    """Every non-OK service in a *hard* state, most recently changed first —
    the "unbehandelte Probleme" view every real monitoring system leads
    with. Soft states (Block H7: a non-OK blip not yet confirmed over
    max_attempts checks) are deliberately excluded — they aren't real
    problems yet. Excludes services under an active Downtime unless
    include_downtime is set, since a downtime means "we already know"."""
    now = datetime.now(timezone.utc)
    await expire_acknowledgements(session, now)
    stmt = (
        select(Service, Agent.name)
        .join(Agent, Agent.id == Service.agent_id)
        .where(Service.state != "OK", Service.state_type == "hard")
    )
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
    await expire_acknowledgements(session, now)
    services = (await session.scalars(select(Service).where(Service.agent_id == agent_id).order_by(Service.name))).all()
    return [await _to_view(session, s, agent.name, now) for s in services]


# The former hardcoded agent thresholds (internal/collect/checks.go), now
# seeded as editable, host-overridable global default rules (Block H6) so
# Memory and Disk show up as rules and the Bossman evaluator — not the
# agent's fixed consts — grades them. Disk is label-agnostic → fans out to
# one "Disk <mount>" service per mount, each overridable by a mount-pinned
# rule. CPU load stays agent-native for now (it grades a per-core-
# normalised value that isn't stored as a metric — see docs/plan.md H6).
_DEFAULT_CHECK_RULES = [
    {"service_name": "Memory", "metric": "mem_used_pct", "comparison": "ge", "warn_threshold": 80.0, "crit_threshold": 90.0},
    {"service_name": "Disk", "metric": "disk_used_pct", "comparison": "ge", "warn_threshold": 80.0, "crit_threshold": 90.0},
]


async def seed_default_check_rules(session: AsyncSession) -> int:
    """Inserts the built-in-check default rules (idempotent): only adds a
    default that isn't already present (matched by service_name+metric),
    and never touches a user-edited or user-deleted rule beyond that. Runs
    at startup. Returns how many were inserted."""
    inserted = 0
    for spec in _DEFAULT_CHECK_RULES:
        exists = await session.scalar(
            select(CheckRule).where(
                CheckRule.service_name == spec["service_name"], CheckRule.metric == spec["metric"]
            )
        )
        if exists is not None:
            continue
        session.add(CheckRule(scope_type="global", scope_value=None, enabled=True, is_default=True, **spec))
        inserted += 1
    if inserted:
        await session.commit()
    return inserted


async def expire_acknowledgements(session: AsyncSession, now: datetime) -> int:
    """Lapses every timed acknowledgement whose expiry has passed
    (CheckMK's "acknowledge for a limited time" — Block H5): the problem
    reverts to unhandled and resurfaces. Called at the top of the problem/
    service read paths so an expired ack is never shown as still handled,
    and by the poller so it happens even with no UI open. Returns the
    number expired. Does not commit — the caller owns the transaction."""
    result = await session.execute(
        update(Service)
        .where(Service.acknowledged.is_(True), Service.ack_expires_at.isnot(None), Service.ack_expires_at <= now)
        .values(acknowledged=False, ack_expires_at=None)
    )
    return result.rowcount or 0


async def acknowledge_service(
    session: AsyncSession, service_id: UUID, comment: str, ack_by: str, expires_at: datetime | None = None
) -> Service | None:
    service = await session.get(Service, service_id)
    if service is None:
        return None
    service.acknowledged = True
    service.ack_comment = comment
    service.ack_by = ack_by
    service.ack_expires_at = expires_at
    await session.commit()
    return service


async def unacknowledge_service(session: AsyncSession, service_id: UUID) -> Service | None:
    service = await session.get(Service, service_id)
    if service is None:
        return None
    service.acknowledged = False
    service.ack_comment = None
    service.ack_by = None
    service.ack_expires_at = None
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
