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

from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, CheckRule, Metric, Service, ServiceStateHistory

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
