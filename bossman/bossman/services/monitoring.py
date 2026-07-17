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

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from uuid import UUID

from sqlalchemy import func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, CheckRule, CheckRuleOuLink, Downtime, Metric, Service, ServiceStateHistory, ValueMap
from bossman.services import gpo, render

logger = logging.getLogger(__name__)

_COMPARISONS = {
    "gt": lambda value, threshold: value > threshold,
    "lt": lambda value, threshold: value < threshold,
    "ge": lambda value, threshold: value >= threshold,
    "le": lambda value, threshold: value <= threshold,
    "eq": lambda value, threshold: value == threshold,
    "ne": lambda value, threshold: value != threshold,
}

def resolve_effective_rule(
    rules: list[CheckRule],
    host_name: str,
    host_groups: list[str],
    metric: str,
    label_value: str | None = None,
    host_ou_ancestry: list | None = None,
    rule_ou_links: dict | None = None,
) -> CheckRule | None:
    """Picks the single rule that governs `metric` (for one label series,
    e.g. a disk mount) on this host, out of every rule that could apply.

    Only enabled rules for this exact metric are considered. The most
    specific label wins first (a rule pinned to this label_value over a
    label-agnostic one — Block H6); within the chosen label pool the winner
    is decided by full GPO precedence (Block L3a, services/gpo.py): normally
    the closest level wins (host > OU(deep→shallow) > group > global), but an
    `enforced` rule at a higher level can't be overridden and pierces block
    inheritance, and an OU on the host's path with `block_inheritance` drops
    inherited non-enforced rules from above it.

    `host_ou_ancestry` is the OU chain root→host-OU (each item exposing
    `.id` and `.block_inheritance`); pass None/[] for a host with no OU
    placement, in which case only global/group/host rules apply and the
    result is identical to the pre-L3a behavior. A rule pinned to a
    *different* label_value is excluded. Returns None if nothing matches."""
    ancestry = host_ou_ancestry or []
    ancestry_depth = {ou.id: i for i, ou in enumerate(ancestry)}
    links = rule_ou_links or {}
    # Deepest OU level on the path that blocks inheritance (None if none).
    blocked_level: int | None = None
    for ou in ancestry:
        if getattr(ou, "block_inheritance", False):
            blocked_level = gpo.LEVEL_OU_BASE + ancestry_depth[ou.id]

    def _rule_ous(rule: CheckRule) -> set:
        # Every OU an OU-scoped rule applies to: its primary scope_ou_id plus
        # any additional OUs linked via check_rule_ou_links (one policy → many
        # OUs). rule.id is None for un-flushed rules (tests) → no extra links.
        ous = set(links.get(rule.id, ())) if rule.id is not None else set()
        if rule.scope_ou_id is not None:
            ous.add(rule.scope_ou_id)
        return ous

    def _scope_matches(rule: CheckRule) -> bool:
        if rule.scope_type == "global":
            return True
        if rule.scope_type == "group":
            # Zabbix gap-analysis Block K2b ("nested host groups"): a rule
            # scoped to "Europe" also governs a host tagged "Europe/Latvia".
            prefix = rule.scope_value + "/"
            return any(g == rule.scope_value or g.startswith(prefix) for g in host_groups)
        if rule.scope_type == "host":
            return rule.scope_value == host_name
        if rule.scope_type == "ou":
            return any(o in ancestry_depth for o in _rule_ous(rule))
        return False

    def _label_matches(rule: CheckRule) -> bool:
        return rule.label_value is None or rule.label_value == label_value

    matching = [r for r in rules if r.enabled and r.metric == metric and _scope_matches(r) and _label_matches(r)]
    if not matching:
        return None

    # Label specificity dominates (Block H6): if any rule is pinned to this
    # exact label, only those compete; otherwise the label-agnostic rules do.
    if label_value is not None:
        specific = [r for r in matching if r.label_value == label_value]
        pool = specific if specific else [r for r in matching if r.label_value is None]
    else:
        pool = matching

    def _level(rule: CheckRule) -> int:
        if rule.scope_type == "host":
            return gpo.LEVEL_HOST
        if rule.scope_type == "ou":
            # The deepest of the rule's OUs that lies on this host's ancestry
            # wins (closest-to-host under GPO); guaranteed non-empty here since
            # _scope_matches already passed.
            depths = [ancestry_depth[o] for o in _rule_ous(rule) if o in ancestry_depth]
            return gpo.LEVEL_OU_BASE + max(depths)
        if rule.scope_type == "group":
            return gpo.LEVEL_GROUP
        return gpo.LEVEL_GLOBAL

    candidates = [
        gpo.GpoCandidate(
            obj=r,
            # None-safe: a freshly constructed (un-flushed) CheckRule hasn't
            # had its column defaults applied yet — treat missing as the
            # DB defaults (not enforced, link_order 100).
            enforced=bool(r.enforced),
            level=_level(r),
            link_order=r.link_order if r.link_order is not None else 100,
            created_ts=r.created_at.timestamp() if r.created_at else 0.0,
            # Group nesting depth as the within-group tiebreak (K2b).
            subrank=r.scope_value.count("/") if r.scope_type == "group" and r.scope_value else 0,
        )
        for r in pool
    ]
    return gpo.resolve_winner(candidates, blocked_level)


async def load_rule_ou_links(session: AsyncSession) -> dict:
    """rule_id → set of additional OU ids from check_rule_ou_links, loaded once
    per resolution pass and passed to resolve_effective_rule so one threshold
    policy can apply to many OUs (beyond its primary scope_ou_id)."""
    out: dict = {}
    for link in (await session.scalars(select(CheckRuleOuLink))).all():
        out.setdefault(link.rule_id, set()).add(link.ou_id)
    return out


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


def hysteresis_blocks_recovery(comparison: str, value: float, recovery_threshold: float) -> bool:
    """Block K6: True if `value` hasn't yet crossed the rule's stricter
    recovery threshold, so a service that just dipped back under the warn
    threshold should hold its current problem state one more poll instead
    of flipping straight to OK — Zabbix's separate "recovery expression"
    (a deadband against a value oscillating right at the boundary). Reuses
    the same comparison direction as the problem condition itself: for a
    "gt"-style rule (problem when value > threshold), recovery requires
    value <= recovery_threshold; for "lt"-style, value >= recovery_threshold."""
    return _COMPARISONS[comparison](value, recovery_threshold)


# How a metric's value is rendered in summaries. Keyed by exact metric name
# (a name's `_pct` suffix is only a hint — cpu_pct actually carries a load
# average, not a percentage, so it must NOT get a % sign). Unknown metrics fall
# back to the suffix heuristic in _metric_kind.
_METRIC_KINDS: dict[str, str] = {
    "disk_used_pct": "percent",
    "mem_used_pct": "percent",
    "cpu_pct": "number",  # despite the name this is a load average, not a percent
}

# Comparison → symbol for readable summaries (">= crit" reads better as "≥ crit").
_CMP_SYMBOLS = {"gt": ">", "lt": "<", "ge": "≥", "le": "≤", "eq": "=", "ne": "≠"}


def _metric_kind(metric: str | None) -> str:
    m = (metric or "").lower()
    if m in _METRIC_KINDS:
        return _METRIC_KINDS[m]
    if m.endswith("_pct") or m.endswith("_percent"):
        return "percent"
    if m.endswith("_bytes"):
        return "bytes"
    if m.endswith("_mib") or m.endswith("_mb"):
        return "mib"
    if "uptime" in m or m.endswith("_seconds") or m.endswith("_secs"):
        return "timespan"
    return "number"


def format_value(value: float | None, metric: str | None = None) -> str:
    """A human-readable metric value (Checkmk-style, see services/render.py):
    percentages, byte sizes, time spans, or a plain rounded number — instead of
    a raw float repr like 0.36648034236027804."""
    if value is None:
        return "n/a"
    kind = _metric_kind(metric)
    if kind == "percent":
        return render.percent(value)
    if kind == "bytes":
        return render.bytes(value)
    if kind == "mib":
        return render.bytes(value * 1024 * 1024)
    if kind == "timespan":
        return render.timespan(value)
    return render.number(value)


def compute_state(
    comparison: str, value: float | None, warn: float | None, crit: float | None, *, metric: str | None = None
) -> tuple[str, str]:
    """Nagios-style threshold evaluation: CRIT is checked before WARN (a
    value that would trip both is CRIT, not WARN); UNKNOWN when there's no
    metric value at all (a stale/never-polled host), not silently OK. The
    summary renders the value (and thresholds) in the metric's unit."""
    if value is None:
        return "UNKNOWN", "no recent metric value"

    v = format_value(value, metric)
    sym = _CMP_SYMBOLS.get(comparison, comparison)
    cmp_fn = _COMPARISONS[comparison]
    if crit is not None and cmp_fn(value, crit):
        return "CRIT", f"{v} {sym} crit {format_value(crit, metric)}"
    if warn is not None and cmp_fn(value, warn):
        return "WARN", f"{v} {sym} warn {format_value(warn, metric)}"
    return "OK", f"{v} within thresholds"


def _condition_trips(comparison: str, value: float | None, threshold: float | None) -> bool:
    if value is None or threshold is None:
        return False
    return _COMPARISONS[comparison](value, threshold)


async def _latest_unlabeled_value(session: AsyncSession, agent_id: UUID, metric: str) -> float | None:
    """The newest sample of a whole-host (unlabeled) metric — the lookup
    Block K9's extra_conditions use to pull in another metric's current
    value alongside the rule's primary one. Deliberately ignores labels
    (mount/iface fan-out): a composite condition combines whole-host
    signals like cpu_pct/load1/mem_pct, not per-mount series."""
    row = await session.scalar(
        select(Metric)
        .where(Metric.agent_id == agent_id, Metric.metric == metric)
        .order_by(Metric.time.desc())
        .limit(1)
    )
    return row.value if row else None


async def evaluate_composite_condition(
    session: AsyncSession, agent_id: UUID, rule: CheckRule, primary_value: float | None
) -> tuple[str, str]:
    """Block K9: combines the rule's primary condition with its
    extra_conditions (other same-host metrics) via condition_logic (AND/OR)
    — a scoped v1 of Zabbix's multi-item boolean trigger expressions.
    Caller only calls this when rule.extra_conditions is truthy and the
    primary compute_state result wasn't already UNKNOWN."""
    combine = all if rule.condition_logic == "AND" else any

    crit_flags = [_condition_trips(rule.comparison, primary_value, rule.crit_threshold)]
    warn_flags = [_condition_trips(rule.comparison, primary_value, rule.warn_threshold)]
    parts = [f"{rule.metric}={primary_value!r}"]

    for cond in rule.extra_conditions:
        value = await _latest_unlabeled_value(session, agent_id, cond["metric"])
        crit_flags.append(_condition_trips(cond["comparison"], value, cond.get("crit_threshold")))
        warn_flags.append(_condition_trips(cond["comparison"], value, cond.get("warn_threshold")))
        parts.append(f"{cond['metric']}={value!r}")

    joined = f" {rule.condition_logic} ".join(parts)
    if combine(crit_flags):
        return "CRIT", f"composite ({rule.condition_logic}) CRIT: {joined}"
    if combine(warn_flags):
        return "WARN", f"composite ({rule.condition_logic}) WARN: {joined}"
    return "OK", f"composite ({rule.condition_logic}) OK: {joined}"


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

    # Block L3a: the host's OU ancestry (root→host-OU), loaded once, so
    # resolve_effective_rule can apply OU-scoped rules + GPO precedence
    # (enforced / block_inheritance). Empty for a host with no OU placement,
    # in which case only global/group/host rules apply (pre-L3a behavior).
    from bossman.services.compiler import resolve_ou_ancestry

    host_ou_ancestry = await resolve_ou_ancestry(session, agent.ou_id)
    rule_ou_links = await load_rule_ou_links(session)

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
        # Collapse to one series per `mount` (the only label that fans out
        # to distinct services): a metric like mem_used_pct can legitimately
        # have several label-sets (e.g. an extra label from a snapshot
        # write) that all map to the SAME mount-less service name — without
        # this, that service would be upserted twice in one pass and the
        # second (unchanged) upsert would clobber the first's notification
        # intent. Newest sample per mount wins.
        by_mount: dict[str | None, Metric] = {}
        for row in latest_rows:
            mount = (row.labels or {}).get("mount")
            if mount not in by_mount or row.time > by_mount[mount].time:
                by_mount[mount] = row
        series: list[tuple[str | None, float | None]] = (
            [(m, r.value) for m, r in by_mount.items()] if by_mount else [(None, None)]
        )

        for mount, value in series:
            rule = resolve_effective_rule(
                list(rules), agent.name, agent.groups, metric, mount,
                host_ou_ancestry=host_ou_ancestry, rule_ou_links=rule_ou_links,
            )
            if rule is None:
                continue

            state, output = compute_state(rule.comparison, value, rule.warn_threshold, rule.crit_threshold, metric=metric)
            # Block K9: a rule with extra_conditions combines its primary
            # metric with other same-host metrics via AND/OR — only once
            # the primary itself has real data (an UNKNOWN host shouldn't
            # be laundered into OK/WARN/CRIT by a composite evaluation).
            if rule.extra_conditions and state != "UNKNOWN":
                state, output = await evaluate_composite_condition(session, agent.id, rule, value)
            # Fan-out naming: a labeled series gets "<service_name> <mount>"
            # so a "Disk" rule reproduces the agent's own "Disk /var" names
            # (and thus overrides them); unlabeled metrics keep the plain name.
            svc_name = f"{rule.service_name} {mount}" if mount else rule.service_name

            max_attempts = rule.max_attempts or DEFAULT_MAX_ATTEMPTS
            svc = await _upsert_service_state(
                session, agent.id, svc_name, state, value, output, now, max_attempts,
                metric=metric, rule_id=rule.id, agent_name=agent.name, agent_tags=agent.tags,
                comparison=rule.comparison, recovery_threshold=rule.recovery_threshold,
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
    agent_tags: dict | None = None,
    comparison: str | None = None,
    recovery_threshold: float | None = None,
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

    # Block K6 (hysteresis): a rule with recovery_threshold set holds a
    # currently non-OK service at its previous state until the value
    # clears that stricter threshold, instead of recovering the moment it
    # dips back under warn_threshold.
    if (
        existing is not None
        and prev_state not in (None, "OK")
        and new_state == "OK"
        and comparison is not None
        and recovery_threshold is not None
        and value is not None
        and hysteresis_blocks_recovery(comparison, value, recovery_threshold)
    ):
        new_state = prev_state
        output = f"{output} (holding at {prev_state}: within recovery deadband, not yet below {recovery_threshold!r})"
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
    existing._notify_agent_tags = agent_tags or {}
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

        # Uptime is a duration in seconds — render it split into days/hours
        # (Checkmk-style) rather than the agent's raw "up 290.6 hours".
        if name.lower() == "uptime" and value is not None:
            output = f"up {render.timespan(value)}"

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
            metric="", rule_id=None, agent_name=agent.name, agent_tags=agent.tags,
        )
        updated.append(svc)

    await session.flush()
    return updated


import re as _re

# Block 2b: retarget an SNMP check without rewriting its (root-owned) .star.
# Translated SNMP checks hardcode `snmpwalk -c public localhost <oids>`. This
# rewrites that argv IN MEMORY at push time so the community + target come from
# the check's params — so the same check can be pointed at any device
# (params: {target, community}). No params → defaults (localhost/public), i.e.
# unchanged behaviour on a normal host. Only the dominant adjacent
# "-c","<community>","<localhost|127.0.0.1>" form is handled; anything else is
# left as-is.
_SNMP_TARGET = _re.compile(r'("-c",\s*)"[A-Za-z0-9_]+"(,\s*)"(?:localhost|127\.0\.0\.1)"')


def parameterize_snmp_star(star: str) -> str:
    if '"snmpwalk"' not in star and '"snmpget"' not in star:
        return star
    if "_snmp_target" in star:  # already parameterized
        return star
    new, n = _SNMP_TARGET.subn(r'\1_snmp_community\2_snmp_target', star)
    if n == 0:
        return star
    return _re.sub(
        r"(def main\(ctx, params\):\n)",
        r'\1    _snmp_community = params.get("community", "public")\n'
        r'    _snmp_target = params.get("target", "localhost")\n',
        new, count=1,
    )


def _sidecar_fqcn(sidecar: str, fallback: str) -> str:
    """The fqcn a pushed check registers under (its sidecar's `fqcn:`, e.g.
    checkmk.sshd_config), so we call the right tool name after pushing."""
    import nestedtext

    try:
        meta = nestedtext.loads(sidecar, top="dict")
        if isinstance(meta, dict) and meta.get("fqcn"):
            return str(meta["fqcn"])
    except nestedtext.NestedTextError:
        pass
    return fallback


async def evaluate_assigned_checks(
    session: AsyncSession, agent: Agent, client, checks_dir: str, *, extra_params: dict | None = None,
) -> list[Service]:
    """Run the host's ASSIGNED Starlark checks and turn each result into a
    Service — the missing execution path (a CheckAssignment resolved but never
    run means the check never appears in Services). Resolves the effective
    checks GPO-style, pushes their modules to the agent, invokes each in normal
    (non-discovery) mode with its merged params, and upserts a Service from the
    returned {state, metrics, details} via the shared ingester. rule_id stays
    NULL (like agent-reported checks); the service is named for the check.
    Best-effort per check; a failure yields an UNKNOWN service, never a raise.
    Does not commit — the poller owns the transaction.

    `extra_params` (Block 3) is merged into every check's params — used for an
    SNMP device polled on its behalf by the co-located poller agent: the checks
    + Services attribute to `agent` (the device), but `client` is the poller's,
    and extra_params carries the device's {target, community} into the (Block 2b
    retargetable) SNMP check."""
    import hashlib
    from pathlib import Path

    from bossman.services import checks_library
    from bossman.services.check_assignments import resolve_host_checks

    effective = await resolve_host_checks(session, agent)
    if not effective:
        return []

    catalog = {c["name"]: c for c in checks_library.list_checks(checks_dir)}
    deliveries: list[dict] = []
    runnable: list[tuple[object, str]] = []
    for ec in effective:
        if not catalog.get(ec.check_name):
            continue
        yaml_path, star_path = checks_library.check_paths(checks_dir, ec.check_name)
        try:
            star = Path(star_path).read_text(encoding="utf-8")
            sidecar = Path(yaml_path).read_text(encoding="utf-8")
        except OSError:
            continue
        fqcn = _sidecar_fqcn(sidecar, f"checks.{ec.check_name}")
        star = parameterize_snmp_star(star)  # Block 2b: retargetable SNMP checks
        deliveries.append({
            "fqcn": fqcn, "star": star, "sidecar": sidecar, "sidecar_format": "nt",
            "sha256": hashlib.sha256(star.encode()).hexdigest(),
        })
        runnable.append((ec, fqcn))
    if not deliveries:
        return []

    try:
        await client.push_modules(deliveries)
    except Exception:  # noqa: BLE001 — a push failure means no assigned-check services this cycle
        logger.exception("pushing assigned checks failed for agent %s", agent.name)
        return []

    now = datetime.now(timezone.utc)
    updated: list[Service] = []
    for ec, fqcn in runnable:
        state, output, value = "UNKNOWN", "check did not return data", None
        try:
            params = dict(getattr(ec, "parameters", {}) or {})
            if extra_params:
                params = {**params, **extra_params}
            res = await client.call_tool(fqcn, params)
            data = (res or {}).get("data") if isinstance(res, dict) else None
            if isinstance(data, dict):
                state = str(data.get("state", "UNKNOWN")).upper()
                if state not in ("OK", "WARN", "CRIT", "UNKNOWN"):
                    state = "UNKNOWN"
                output = str(data.get("details") or (res or {}).get("msg") or "")
                metrics = data.get("metrics")
                if isinstance(metrics, dict):
                    for v in metrics.values():
                        if isinstance(v, (int, float)):
                            value = float(v)
                            break
        except Exception:  # noqa: BLE001 — one bad check must not sink the cycle
            output = "check execution failed"
        svc = await _upsert_service_state(
            session, agent.id, ec.check_name, state, value, output, now, DEFAULT_MAX_ATTEMPTS,
            metric=ec.check_name, rule_id=None, agent_name=agent.name, agent_tags=agent.tags,
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
    """One Service plus the things that don't live on the row itself: its
    host's name (a join), whether it's currently covered by an active
    Downtime (a point-in-time computation, not stored state), and — Block
    K4 — the value-mapped label for its raw value, if its owning CheckRule
    has a ValueMap attached."""

    service: Service
    agent_name: str
    in_downtime: bool
    mapped_value: str | None = None
    # F-17: the owning CheckRule's thresholds, so the UI can show *why* a
    # service is WARN/CRIT ("39.8 % — warn ≥ 80, crit ≥ 90") instead of a
    # bare state pill. Null when no rule materialises this service (agent
    # builtins like Uptime, or an assigned Starlark check that self-grades).
    warn_threshold: float | None = None
    crit_threshold: float | None = None
    comparison: str | None = None


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


def _mapped_value_from(value_map: "ValueMap | None", value: float) -> str | None:
    """Block K4: the human label for a raw value via a ValueMap. Tries the
    whole-number form of the key first ("0") since that's how an operator
    naturally authors a mapping, falling back to the raw float's string."""
    if value_map is None:
        return None
    if value == int(value):
        key = str(int(value))
        if key in value_map.mappings:
            return value_map.mappings[key]
    return value_map.mappings.get(str(value))


async def _to_view(session: AsyncSession, service: Service, agent_name: str, now: datetime) -> ServiceView:
    in_downtime = await is_in_downtime(session, service.agent_id, service.name, now)
    # One rule fetch feeds both the K4 value-mapped label and the F-17
    # thresholds — the two things about a service that live on its rule, not
    # its row. Builtins with no rule_id keep all of these null.
    mapped_value = None
    warn = crit = comparison = None
    if service.rule_id is not None:
        rule = await session.get(CheckRule, service.rule_id)
        if rule is not None:
            warn, crit, comparison = rule.warn_threshold, rule.crit_threshold, rule.comparison
            if service.value is not None and rule.value_map_id is not None:
                mapped_value = _mapped_value_from(await session.get(ValueMap, rule.value_map_id), service.value)
    return ServiceView(
        service=service,
        agent_name=agent_name,
        in_downtime=in_downtime,
        mapped_value=mapped_value,
        warn_threshold=warn,
        crit_threshold=crit,
        comparison=comparison,
    )


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
    tag: str | None = None,
) -> list[ServiceView]:
    """Every non-OK service in a *hard* state, most recently changed first —
    the "unbehandelte Probleme" view every real monitoring system leads
    with. Soft states (Block H7: a non-OK blip not yet confirmed over
    max_attempts checks) are deliberately excluded — they aren't real
    problems yet. Excludes services under an active Downtime unless
    include_downtime is set, since a downtime means "we already know".
    `tag` (Block K7) is "name" (any value) or "name:value" (exact), matched
    against the problem's host's Agent.tags."""
    now = datetime.now(timezone.utc)
    await expire_acknowledgements(session, now)
    stmt = (
        select(Service, Agent.name)
        .join(Agent, Agent.id == Service.agent_id)
        .where(Service.state != "OK", Service.state_type == "hard")
        # Hide the infra poller's own services from Problems (is_infra_agent).
        .where(Agent.agent_metadata["role"].astext.is_distinct_from("poller"))
    )
    if state is not None:
        stmt = stmt.where(Service.state == state)
    if host is not None:
        stmt = stmt.where(Agent.name == host)
    if acknowledged is not None:
        stmt = stmt.where(Service.acknowledged == acknowledged)
    if tag is not None:
        tag_name, _, tag_value = tag.partition(":")
        stmt = stmt.where(Agent.tags.has_key(tag_name))
        if tag_value:
            stmt = stmt.where(Agent.tags[tag_name].astext == tag_value)
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


_AVAIL_STATES = ("OK", "WARN", "CRIT", "UNKNOWN")


@dataclass
class AvailabilitySlice:
    state: str
    seconds: float
    percent: float


@dataclass
class AvailabilityReport:
    """A service's uptime split over [start, end], reconstructed from the
    hard-state timeline (service_state_history holds only hard transitions
    since Block H7, so soft blips don't count against an SLA — exactly what
    CheckMK's availability view does). Percentages are of *monitored* time:
    any leading span before the first recorded state (a service we have no
    record for yet) is left uncounted rather than charged as downtime."""

    agent_id: UUID
    service_name: str
    start: datetime
    end: datetime
    window_seconds: float
    monitored_seconds: float
    slices: list[AvailabilitySlice]
    ok_percent: float
    state_changes: int


async def compute_availability(
    session: AsyncSession, agent_id: UUID, service_name: str, start: datetime, end: datetime
) -> AvailabilityReport:
    """Time-in-state for one service. Carry-in = the last hard state before
    `start`; that state holds until the next recorded change, and the tail
    holds until `end`."""
    carry_in = await session.scalar(
        select(ServiceStateHistory.state)
        .where(
            ServiceStateHistory.agent_id == agent_id,
            ServiceStateHistory.service_name == service_name,
            ServiceStateHistory.time < start,
        )
        .order_by(ServiceStateHistory.time.desc())
        .limit(1)
    )
    changes = (
        await session.scalars(
            select(ServiceStateHistory)
            .where(
                ServiceStateHistory.agent_id == agent_id,
                ServiceStateHistory.service_name == service_name,
                ServiceStateHistory.time >= start,
                ServiceStateHistory.time <= end,
            )
            .order_by(ServiceStateHistory.time.asc())
        )
    ).all()

    durations: dict[str, float] = {}
    current: str | None = carry_in
    cursor = start
    for ch in changes:
        if current is not None:
            seg = (ch.time - cursor).total_seconds()
            if seg > 0:
                durations[current] = durations.get(current, 0.0) + seg
        current = ch.state
        cursor = ch.time
    if current is not None:
        seg = (end - cursor).total_seconds()
        if seg > 0:
            durations[current] = durations.get(current, 0.0) + seg

    monitored = sum(durations.values())
    slices = [
        AvailabilitySlice(
            state=st,
            seconds=durations.get(st, 0.0),
            percent=(durations.get(st, 0.0) / monitored * 100.0) if monitored > 0 else 0.0,
        )
        for st in _AVAIL_STATES
    ]
    return AvailabilityReport(
        agent_id=agent_id,
        service_name=service_name,
        start=start,
        end=end,
        window_seconds=(end - start).total_seconds(),
        monitored_seconds=monitored,
        slices=slices,
        ok_percent=next((s.percent for s in slices if s.state == "OK"), 0.0),
        state_changes=len(changes),
    )


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
    # Consumed IOPS per server. No universal threshold (hardware-dependent), so
    # the defaults sit high and rarely fire — the value is the point; operators
    # tighten it per host/OU. Surfaces IOPS as a first-class service.
    {"service_name": "Disk IOPS", "metric": "disk_iops", "comparison": "ge", "warn_threshold": 5000.0, "crit_threshold": 10000.0},
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


def is_infra_agent(agent: Agent) -> bool:
    """True for infrastructure agents that run silently and must NOT appear as
    monitored hosts — currently the co-located SNMP/SSH poller ("selecta"). It
    exists only to poll agent-less devices on their behalf; it is not itself a
    host anyone monitors."""
    return (agent.agent_metadata or {}).get("role") == "poller"


async def mark_poller_agent(session: AsyncSession, name: str) -> None:
    """Mark the co-located poller as a hidden proxy (selecta): mode=proxy +
    agent_metadata.role=poller, so the Hosts/fleet/problems views filter it out
    (is_infra_agent) while it keeps polling SNMP/SSH devices. Idempotent."""
    agent = await session.scalar(select(Agent).where(Agent.name == name))
    if agent is None:
        return
    changed = False
    if agent.mode != "proxy":
        agent.mode = "proxy"
        changed = True
    meta = dict(agent.agent_metadata or {})
    if meta.get("role") != "poller":
        meta["role"] = "poller"
        agent.agent_metadata = meta
        changed = True
    if changed:
        await session.commit()


async def fleet_summary(session: AsyncSession) -> FleetSummary:
    """Counters for the fleet overview page: hosts by enrollment state,
    services by monitoring state, and how many are genuinely open problems
    (non-OK, unacknowledged, not in downtime) — the number that should
    actually draw a human's attention."""
    all_agents = (await session.scalars(select(Agent))).all()
    infra_ids = {a.id for a in all_agents if is_infra_agent(a)}
    agents = [a for a in all_agents if a.id not in infra_ids]
    hosts_by_enrollment: dict[str, int] = {}
    for a in agents:
        hosts_by_enrollment[a.enrollment_state] = hosts_by_enrollment.get(a.enrollment_state, 0) + 1

    now = datetime.now(timezone.utc)
    services = (await session.scalars(select(Service))).all()
    services_by_state: dict[str, int] = {"OK": 0, "WARN": 0, "CRIT": 0, "UNKNOWN": 0}
    open_problems = 0
    for s in services:
        if s.agent_id in infra_ids:
            continue  # hide the poller's own services from fleet counts
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
    agents = [a for a in (await session.scalars(select(Agent).order_by(Agent.name))).all() if not is_infra_agent(a)]
    names_by_id = {a.id: a.name for a in agents}

    services = (await session.scalars(select(Service))).all()
    services_by_agent: dict[UUID, list[Service]] = {}
    for s in services:
        services_by_agent.setdefault(s.agent_id, []).append(s)

    cpu_by_agent = await _latest_metric_by_agent(session, "cpu_load1")
    mem_by_agent = await _latest_metric_by_agent(session, "mem_used_pct")
    disk_by_agent = await _latest_disk_used_pct_max(session)

    # Piggyback hosts (Docker containers, Proxmox/vCenter VMs) report CPU/memory
    # under container_*/vm_* names, not cpu_load1/mem_used_pct — fall back to
    # those so a container/VM host isn't blank in the fleet table.
    cpu_container = await _latest_metric_by_agent(session, "container_cpu_pct")
    cpu_vm = await _latest_metric_by_agent(session, "vm_cpu_pct")
    mem_container = await _latest_metric_by_agent(session, "container_mem_pct")
    mem_vm = await _latest_metric_by_agent(session, "vm_mem_pct")

    def _cpu(aid):
        v = cpu_by_agent.get(aid)
        return v if v is not None else cpu_container.get(aid, cpu_vm.get(aid))

    def _mem(aid):
        v = mem_by_agent.get(aid)
        return v if v is not None else mem_container.get(aid, mem_vm.get(aid))

    out = []
    for agent in agents:
        agent_services = services_by_agent.get(agent.id, [])
        counts = {"OK": 0, "WARN": 0, "CRIT": 0, "UNKNOWN": 0}
        worst = "OK"
        for s in agent_services:
            # A soft (not-yet-confirmed) non-OK state is "pending", not a problem
            # yet — it must NOT flip the host to WARN/CRIT, so the fleet status
            # stays consistent with the Problems view (which is hard-state only).
            effective = s.state if (s.state == "OK" or s.state_type == "hard") else "OK"
            counts[effective] = counts.get(effective, 0) + 1
            if _STATE_SEVERITY.get(effective, 0) > _STATE_SEVERITY.get(worst, 0):
                worst = effective

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
                cpu_load=_cpu(agent.id),
                mem_used_pct=_mem(agent.id),
                disk_used_pct_max=disk_by_agent.get(agent.id),
                service_counts=counts,
            )
        )
    return out
