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
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from uuid import UUID

from sqlalchemy import func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, CheckRule, CheckRuleOuLink, Downtime, Metric, Service, ServiceStateHistory, ValueMap
from bossman.services import gpo, render, rule_conditions

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
    host_site_ids: set | None = None,
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
    site_ids = host_site_ids or set()
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
        if rule.scope_type == "site":
            return rule.scope_site_id in site_ids
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
        if rule.scope_type == "site":
            return gpo.LEVEL_SITE
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


@dataclass
class RuleExplanation:
    """One candidate rule in the 'Effective parameters' view (Block E): the
    rule, the precedence level it competes at on this host, whether it won, and
    a human reason. Ranked most-authoritative first."""

    rule: CheckRule
    level: int
    is_winner: bool
    reason: str


def explain_effective_rules(
    rules: list[CheckRule],
    host_name: str,
    host_groups: list[str],
    metric: str,
    label_value: str | None = None,
    host_ou_ancestry: list | None = None,
    rule_ou_links: dict | None = None,
    host_site_ids: set | None = None,
) -> list[RuleExplanation]:
    """The 'why' behind resolve_effective_rule (Block E, Checkmk's effective-
    parameters page): return EVERY rule that applies to `metric`/`label_value`
    on this host, ranked exactly as the resolver ranks them, with the winner
    flagged and a one-line reason. Empty if no rule applies.

    This mirrors resolve_effective_rule's matching + level + precedence so the
    explanation is precisely what the poller acts on — never a second opinion.
    OUR precedence is the OPPOSITE of Checkmk's top-first: the closest-to-host
    (deepest level) rule wins, unless a higher-level rule is `enforced` or an OU
    on the path blocks inheritance (docs/policy-page-rework.md)."""
    ancestry = host_ou_ancestry or []
    ancestry_depth = {ou.id: i for i, ou in enumerate(ancestry)}
    links = rule_ou_links or {}
    site_ids = host_site_ids or set()
    blocked_level: int | None = None
    for ou in ancestry:
        if getattr(ou, "block_inheritance", False):
            blocked_level = gpo.LEVEL_OU_BASE + ancestry_depth[ou.id]

    def _rule_ous(rule: CheckRule) -> set:
        ous = set(links.get(rule.id, ())) if rule.id is not None else set()
        if rule.scope_ou_id is not None:
            ous.add(rule.scope_ou_id)
        return ous

    def _scope_matches(rule: CheckRule) -> bool:
        if rule.scope_type == "global":
            return True
        if rule.scope_type == "group":
            prefix = rule.scope_value + "/"
            return any(g == rule.scope_value or g.startswith(prefix) for g in host_groups)
        if rule.scope_type == "host":
            return rule.scope_value == host_name
        if rule.scope_type == "ou":
            return any(o in ancestry_depth for o in _rule_ous(rule))
        if rule.scope_type == "site":
            return rule.scope_site_id in site_ids
        return False

    def _label_matches(rule: CheckRule) -> bool:
        return rule.label_value is None or rule.label_value == label_value

    def _level(rule: CheckRule) -> int:
        if rule.scope_type == "host":
            return gpo.LEVEL_HOST
        if rule.scope_type == "ou":
            depths = [ancestry_depth[o] for o in _rule_ous(rule) if o in ancestry_depth]
            return gpo.LEVEL_OU_BASE + max(depths)
        if rule.scope_type == "site":
            return gpo.LEVEL_SITE
        if rule.scope_type == "group":
            return gpo.LEVEL_GROUP
        return gpo.LEVEL_GLOBAL

    matching = [r for r in rules if r.enabled and r.metric == metric and _scope_matches(r) and _label_matches(r)]
    if not matching:
        return []

    # Label specificity dominates (Block H6): rules pinned to this exact label
    # exclude the label-agnostic ones. Rules dropped here get a reason so the
    # view still lists them (why they don't compete), rather than hiding them.
    excluded_by_label: list[CheckRule] = []
    if label_value is not None:
        specific = [r for r in matching if r.label_value == label_value]
        if specific:
            excluded_by_label = [r for r in matching if r.label_value is None]
            pool = specific
        else:
            pool = [r for r in matching if r.label_value is None]
    else:
        pool = matching

    winner = resolve_effective_rule(
        list(rules), host_name, host_groups, metric, label_value,
        host_ou_ancestry=host_ou_ancestry, rule_ou_links=rule_ou_links, host_site_ids=host_site_ids,
    )
    winner_id = winner.id if winner is not None else None
    winner_level = _level(winner) if winner is not None else None
    any_enforced = winner is not None and bool(winner.enforced)

    out: list[RuleExplanation] = []
    for r in pool:
        lvl = _level(r)
        is_winner = winner_id is not None and r.id == winner_id
        if is_winner:
            reason = "enforced — cannot be overridden" if r.enforced else "closest to host wins"
        elif blocked_level is not None and not r.enforced and lvl < blocked_level:
            reason = "blocked by OU inheritance"
        elif any_enforced and not r.enforced:
            reason = "overridden by an enforced rule"
        elif winner_level is not None and lvl < winner_level:
            reason = "overridden by a more specific scope"
        elif winner_level is not None and lvl > winner_level:
            # Only reachable when an enforced higher-level rule beat this deeper one.
            reason = "loses to an enforced rule above"
        else:
            reason = "overridden (same level, older/lower priority)"
        out.append(RuleExplanation(rule=r, level=lvl, is_winner=is_winner, reason=reason))

    for r in excluded_by_label:
        out.append(RuleExplanation(rule=r, level=_level(r), is_winner=False, reason=f"does not apply — pinned to a different label"))

    # Most-authoritative first: winner, then by descending level (closest first).
    out.sort(key=lambda e: (not e.is_winner, -e.level))
    return out


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
# L7: flapping on the reference algorithm instead of a raw change count.
#
# The old test — "5 state changes within 30 minutes" — is not normalised against how often
# the service is actually checked. A service polled every 10 minutes can only produce three
# results in that window, so it can never flap; one polled every 20 seconds flaps on a
# handful of blips out of ninety checks. Nagios/Checkmk instead keep the last 21 results and
# compute a WEIGHTED percentage of transitions among them, with recent transitions counting
# more (0.8 rising to 1.2), and apply hysteresis: flapping starts above the high threshold and
# only stops below the low one, so a service does not oscillate in and out of "flapping".
#
# Thresholds are the reference's own shipped defaults
# (omd/packages/nagios/skel/etc/nagios/nagios.d/flapping.cfg: low 5.0, high 20.0).
_FLAP_HISTORY = 21
_FLAP_START_PCT = 20.0
_FLAP_STOP_PCT = 5.0
# L1 fallback for callers that have no Settings (see stale_after_for, which is what
# the poller uses). Equals the shipped default of staleness_factor 4 x 60 s poll
# interval; kept as its own constant so a caller without settings degrades to the
# same behaviour instead of silently to "never stale".
_DEFAULT_STALE_AFTER = timedelta(minutes=4)


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


def percent_state_change(states: list[str]) -> float:
    """Nagios/Checkmk's `percent_state_change` over a result history, oldest first.

    Each of the n-1 adjacent pairs is a possible transition, weighted linearly from 0.8
    (oldest) to 1.2 (newest) so that recent instability counts more than old instability; the
    result is the weighted share of pairs that actually changed, in percent.

    Fewer than two results is 0.0 — not "unknown". A service with one result has no history to
    be unstable in, and returning something else would make a brand-new service flap.
    """
    if len(states) < 2:
        return 0.0
    pairs = len(states) - 1
    if pairs == 1:
        weights = [1.0]
    else:
        weights = [0.8 + (0.4 * i / (pairs - 1)) for i in range(pairs)]
    changed = sum(w for w, (a, b) in zip(weights, zip(states, states[1:])) if a != b)
    return (changed / sum(weights)) * 100.0


def is_flapping_now(states: list[str], currently_flapping: bool) -> bool:
    """Hysteresis: start above the high threshold, stop only below the low one.

    Without the gap a service sitting near the threshold would be declared flapping and
    un-flapping on alternating checks — which is itself a form of flapping, in the flag.
    """
    pct = percent_state_change(states)
    if currently_flapping:
        return pct >= _FLAP_STOP_PCT
    return pct > _FLAP_START_PCT


def append_state_history(history: list | None, state: str) -> list[str]:
    """The last _FLAP_HISTORY results, oldest first. Fixed length, so this never grows."""
    out = [str(s) for s in (history or [])]
    out.append(state)
    return out[-_FLAP_HISTORY:]


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


# L2: the host's own reachability, carried as a reserved Service rather than as extra
# columns on `agents`. That is not a shortcut — it is the reason the feature is small:
# a Service row already brings soft/hard debouncing (so one transient failure does not
# page), state history, acknowledgement with expiry, downtime coverage, flapping
# suppression, the Problems view, notification rules and escalation. A parallel
# host-state machine beside `services` would have had to re-earn every one of those.
#
# The name is reserved: no rule may produce it, and L3's suppression keys off it.
HOST_ALIVE_SERVICE = "Host alive"
# Reserved service carrying the count of managed config files drifted from desired
# (poller._enforce_config_drift upserts it each cycle; WARN when > 0).
CONFIG_DRIFT_SERVICE = "Config drift"


def _version_suffix(version: str) -> str:
    """" v0.57.36" for a version number, " (poller)" for anything else, "" for nothing.

    Not every agent reports a dotted version: the infra poller answers "poller", which the
    unconditional "v" prefix rendered as "vpoller" — read as a typo rather than as an
    identifier. Only prefix when the string actually looks like a version.
    """
    v = (version or "").strip()
    if not v:
        return ""
    return f" v{v}" if v[0].isdigit() else f" ({v})"


async def parent_ids(session: AsyncSession, agent: Agent) -> list[UUID]:
    """L6: this host's reachability parents, explicit ones plus the implicit proxy.

    `Agent.parent_agent_id` is included without anybody configuring it, because it genuinely
    IS a reachability parent: if Bossman cannot reach a proxy, it cannot reach the satellites
    behind it. The `host_parents` table carries only what cannot be derived — a switch or
    router in the path.
    """
    from bossman.db.models import HostParent

    explicit = list(
        (
            await session.scalars(
                select(HostParent.parent_agent_id).where(HostParent.child_agent_id == agent.id)
            )
        ).all()
    )
    if agent.parent_agent_id and agent.parent_agent_id not in explicit:
        explicit.append(agent.parent_agent_id)
    return explicit


async def unreachable_via(session: AsyncSession, agent: Agent) -> list[str]:
    """The parents that are confirmed down, but ONLY if every parent is.

    Checkmk's rule: one reachable parent makes the host's own failure its own fault again. So
    an empty result means "this host is DOWN", and a non-empty one means "we cannot even get
    there" — a different statement, and not one to page about.
    """
    ids = await parent_ids(session, agent)
    if not ids:
        return []
    down = await hard_down_agent_ids(session, ids)
    if len(down) != len(set(ids)):
        return []
    names = (await session.scalars(select(Agent.name).where(Agent.id.in_(list(down))))).all()
    return sorted(names)


async def newest_sample_at(session: AsyncSession, agent_id: UUID) -> datetime | None:
    """When this host last produced ANY metric sample; None if it never has."""
    return await session.scalar(
        select(func.max(Metric.time)).where(Metric.agent_id == agent_id)
    )


async def update_host_alive(
    session: AsyncSession,
    agent: Agent,
    *,
    reached: bool | None,
    now: datetime,
    stale_after: timedelta,
    detail: str = "",
) -> Service:
    """The host's own up/down verdict, as its own service — our ping equivalent.

    Checkmk treats agent contact as the host check: if the agent is stale, the host is
    DOWN. So there are two ways to be down here, and both are CRIT:

    1. **No answer.** The poll could not reach the agent at all.
    2. **Stale.** The agent answers, but its freshest sample is older than
       `stale_after`. An agent whose sampler has died, or whose clock/collector has
       wedged, is not a healthy host just because its HTTP port accepts connections —
       that distinction is exactly what "agent status equals a ping" rules out.

    `reached=None` means "not contacted directly", which is the normal case for a
    satellite: its data arrives relayed through a proxy, so freshness is the only signal
    available and rule 2 alone decides. Before this, satellites had no host verdict at
    all — a relay that quietly stopped delivering looked identical to a healthy host.

    Being down is a problem in its own right unless a downtime says it is expected, and
    that needs no special case: a host-wide downtime (a `Downtime` row with service_name
    NULL) already covers this service like any other, so it suppresses the page and drops
    out of the Problems view while the state stays honestly CRIT.

    Debounced with DEFAULT_MAX_ATTEMPTS, so one dropped poll is `soft` and only a
    genuinely absent host reaches `hard` and pages.
    """
    sampled_at = await newest_sample_at(session, agent.id)
    stale = is_stale_sample(sampled_at, now, stale_after)
    version = _version_suffix(agent.agent_version)

    if reached is False:
        # L6: is this host down, or merely out of reach? If every parent is itself confirmed
        # down, we cannot distinguish a healthy host behind a dead switch from a dead one —
        # so say so (UNKNOWN, not CRIT) and let the parent's own CRIT be the page. Same rule
        # as L3: one problem per outage.
        blocked_by = await unreachable_via(session, agent)
        if blocked_by:
            state = "UNKNOWN"
            output = f"unreachable — {' and '.join(blocked_by)} {'are' if len(blocked_by) > 1 else 'is'} down"
        else:
            # Name the actual failure — "no answer" alone sends the operator hunting for a
            # reason the poller already knows (DNS, refused, TLS, wrong token, timeout).
            state = "CRIT"
            output = f"no answer from {agent.address or 'the agent'}"
            if detail:
                output = f"{output}: {detail}"
    elif stale:
        state = "CRIT"
        if sampled_at is None:
            output = f"agent{version} has never delivered data"
        else:
            output = f"agent{version} is stale: no data for {render.timespan((now - sampled_at).total_seconds())}"
        if reached:
            # Worth spelling out: the port answered. Otherwise this reads like a network
            # fault and the operator looks in the wrong place.
            output = f"{output} (its API did answer)"
    else:
        state = "OK"
        age = render.timespan((now - sampled_at).total_seconds()) if sampled_at else "?"
        how = "agent responded" if reached else "relayed"
        output = f"{how}{version}, data {age} old"

    svc = await _upsert_service_state(
        session,
        agent.id,
        HOST_ALIVE_SERVICE,
        state,
        None,
        output,
        now,
        DEFAULT_MAX_ATTEMPTS,
        metric="",
        rule_id=None,
        agent_name=agent.name,
        agent_tags=agent.tags,
    )
    # L6: stamped for the dispatcher, the same way the state machine stamps _notify_event —
    # an unreachable host must not page at all. Its state is honestly UNKNOWN in the UI, but
    # the page belongs to whichever parent is actually down. Carried as a transient attribute
    # rather than re-derived at dispatch time, so the decision is made once, where the parent
    # lookup already happened.
    svc._unreachable = state == "UNKNOWN" and output.startswith("unreachable")  # type: ignore[attr-defined]
    return svc


async def hard_down_agent_ids(session: AsyncSession, agent_ids: Iterable[UUID]) -> set[UUID]:
    """Which of these hosts are confirmed (hard) down — the input to L3's suppression."""
    ids = list({a for a in agent_ids})
    if not ids:
        return set()
    rows = await session.scalars(
        select(Service.agent_id).where(
            Service.agent_id.in_(ids),
            Service.name == HOST_ALIVE_SERVICE,
            Service.state != "OK",
            Service.state_type == "hard",
        )
    )
    return set(rows.all())


def stale_after_for(settings) -> timedelta:
    """How old a metric may be and still count as a statement about *now*.

    Checkmk asks the same question as `staleness = age / check_interval` against a
    `staleness_threshold` of 1.5 (`cmk/gui/general_config.py:366`). We need a bigger
    factor than 1.5, and the reason is structural rather than sloppy: Checkmk's core
    produces the check result itself at the moment it checks, so age ≈ 0 at evaluation.
    Ours travels two hops — the agent samples on its own cadence, then a poll pulls it,
    then the rule is evaluated — so a perfectly healthy reading is already one sample
    interval old before we ever see it.

    Measured on the live fleet rather than guessed: for the 7 healthy hosts the newest
    metric was 61-108 s old at evaluation, and the largest gap between two consecutive
    cpu_pct samples over two hours was 120 s. So Checkmk's 1.5 x 60 s = 90 s would
    already mark healthy hosts stale. The default factor of 4 (240 s) clears both the
    observed worst age and the worst sample gap with room to spare, while still noticing
    a dead host within four minutes.
    """
    return timedelta(seconds=settings.staleness_factor * settings.poll_interval_seconds)


def is_stale_sample(sample_time: datetime | None, now: datetime, stale_after: timedelta) -> bool:
    """True when a sample is too old to be judged (or there is no sample at all)."""
    return sample_time is None or (now - sample_time) > stale_after


def _no_data_output(sample_time: datetime | None, now: datetime) -> str:
    """Says how long the silence has lasted — "UNKNOWN" alone does not distinguish
    "never sampled" from "gone since Tuesday", and that difference is the whole point."""
    if sample_time is None:
        return "no data (never sampled)"
    return f"no data for {render.timespan((now - sample_time).total_seconds())}"


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


async def evaluate_host(
    session: AsyncSession, agent: Agent, *, stale_after: timedelta | None = None
) -> list[Service]:
    """Re-evaluates every check_rules-derived service for one agent
    against its most recently polled metric values, upserting `services`
    and recording a `service_state_history` row on each state change.
    Meant to be called right after the poller writes fresh metrics for
    this agent (same session, not yet committed — evaluate_host reads its
    own just-written rows via that same, still-open transaction). Does
    not commit; the caller owns the transaction boundary.

    `stale_after` bounds how old a metric may be and still be judged (L1); a
    reading older than that yields UNKNOWN "no data for X" instead of its last
    verdict. Callers with Settings pass `stale_after_for(settings)`; the default
    covers the paths that have none."""
    if stale_after is None:
        stale_after = _DEFAULT_STALE_AFTER
    rules = (await session.scalars(select(CheckRule).where(CheckRule.enabled == True))).all()  # noqa: E712
    metrics_needed = sorted({r.metric for r in rules})
    if not metrics_needed:
        return []

    # Block L3a: the host's OU ancestry (root→host-OU), loaded once, so
    # resolve_effective_rule can apply OU-scoped rules + GPO precedence
    # (enforced / block_inheritance). Empty for a host with no OU placement,
    # in which case only global/group/host rules apply (pre-L3a behavior).
    from bossman.services.compiler import resolve_ou_ancestry, resolve_site_ids

    host_ou_ancestry = await resolve_ou_ancestry(session, agent.ou_id)
    rule_ou_links = await load_rule_ou_links(session)
    # Site (subnet) scope: the Sites this host's primary IP falls into, so
    # site-scoped threshold rules apply (precedence LEVEL_SITE, between OU and host).
    host_site_ids = await resolve_site_ids(session, agent)

    # Checkmk's six condition fields, applied BEFORE GPO resolution: the condition decides
    # whether a rule applies to this host at all, GPO then picks the winner among those
    # that do. Filtering here keeps resolve_effective_rule a pure function over a rule
    # list, and costs one context build per host instead of one per rule.
    #
    # Only the HOST-level fields are judged here: a threshold rule already NAMES its
    # service, so `service_description`/`service_label_groups` would be circular. They are
    # left unevaluated (rule_conditions skips them when service_name is None) rather than
    # silently failing the rule.
    if any(r.conditions for r in rules):
        from bossman.services.check_assignments import build_match_context

        cond_ctx = await build_match_context(session, agent, host_ou_ancestry)
        rules = [r for r in rules if rule_conditions.matches(r.conditions, cond_ctx)]
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
        # Carry each series' sample TIME alongside its value: a value is only a
        # verdict about now if it is recent (see is_stale_sample below). The
        # aged-out case deliberately keeps its label, so "Disk /" stays "Disk /"
        # and goes UNKNOWN — dropping the row here instead would collapse every
        # mount into one label-less "Disk" service and leave the real per-mount
        # services untouched at their last OK forever, which is the bug.
        series: list[tuple[str | None, float | None, datetime | None]] = (
            [(m, r.value, r.time) for m, r in by_mount.items()] if by_mount else [(None, None, None)]
        )

        for mount, value, sample_time in series:
            rule = resolve_effective_rule(
                list(rules), agent.name, agent.groups, metric, mount,
                host_ou_ancestry=host_ou_ancestry, rule_ou_links=rule_ou_links,
                host_site_ids=host_site_ids,
            )
            if rule is None:
                continue

            # L1: judge only a CURRENT reading. Passing an aged-out value on to
            # compute_state is what let a host silent for 26 days keep reporting
            # OK, re-timestamped every poll cycle.
            if is_stale_sample(sample_time, now, stale_after):
                state, output = "UNKNOWN", _no_data_output(sample_time, now)
                value = None
            else:
                state, output = compute_state(
                    rule.comparison, value, rule.warn_threshold, rule.crit_threshold, metric=metric
                )
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
        await session.flush()  # the timeline row lands before anything reads it back

    # L7: every result — not only the changes — feeds the flapping test, so the percentage is
    # normalised against how often this service is actually checked.
    existing.recent_states = append_state_history(existing.recent_states, existing.state)
    existing.is_flapping = is_flapping_now(existing.recent_states, existing.is_flapping)

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
        # NB: agent-reported checks (CPU load, Disk, Uptime, …) are NOT turned
        # into perfdata history series. Their data already exists as first-class
        # telemetry (cpu_load1, disk_used_pct{mount}, uptime_seconds), so storing
        # their perfdata again would duplicate those series under worse names
        # ("Disk /_used_pct") and re-inflate the cardinality this project spent
        # real effort cutting. Perfdata→series is done ONLY in
        # evaluate_assigned_checks, for assigned checks that have no telemetry.

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
# rewrites that argv IN MEMORY at push time so the connection args come from the
# check's params — so the same check can be pointed at any device. Supports BOTH
# SNMP v2c ({community}) and v3 ({snmp_version:"v3", sec_level, sec_name,
# auth_proto/auth_pass, priv_proto/priv_pass, context}). No params → v2c
# localhost/public, i.e. unchanged behaviour on a normal host. Only the dominant
# adjacent "snmpwalk|snmpget","-c","<community>","<localhost|127.0.0.1>" form is
# handled; anything else is left as-is.
#
# We can't splice a variable-length arg list into the literal (go.starlark.net has
# no `[*a, *b]` unpacking), so we rewrite `["snmpwalk", "-c", "c", "host", …]` to
# `["snmpwalk"] + _snmp_conn + […]` and compute _snmp_conn (a plain list, built
# with `+`) at the top of main — v2c is `["-c", community, target]`, v3 the full
# -v3/-l/-u/-a/-A/-x/-X/-n flag sequence gated by the security level.
_SNMP_CONN = _re.compile(
    r'("(?:snmpwalk|snmpget)")\s*,\s*"-c"\s*,\s*"[A-Za-z0-9_]+"\s*,\s*"(?:localhost|127\.0\.0\.1)"\s*,?\s*'
)

_SNMP_CONN_PREAMBLE = (
    '    _snmp_target = params.get("target", "localhost")\n'
    '    _snmp_version = params.get("snmp_version", "v2c")\n'
    '    if _snmp_version == "v3":\n'
    '        _snmp_level = params.get("sec_level", "authPriv")\n'
    '        _snmp_conn = ["-v3", "-l", _snmp_level, "-u", params.get("sec_name", "")]\n'
    '        if _snmp_level != "noAuthNoPriv":\n'
    '            _snmp_conn = _snmp_conn + ["-a", params.get("auth_proto", "SHA"), "-A", params.get("auth_pass", "")]\n'
    '        if _snmp_level == "authPriv":\n'
    '            _snmp_conn = _snmp_conn + ["-x", params.get("priv_proto", "AES"), "-X", params.get("priv_pass", "")]\n'
    '        if params.get("context", ""):\n'
    '            _snmp_conn = _snmp_conn + ["-n", params.get("context", "")]\n'
    '        _snmp_conn = _snmp_conn + [_snmp_target]\n'
    '    else:\n'
    '        _snmp_conn = ["-c", params.get("community", "public"), _snmp_target]\n'
)


def parameterize_snmp_star(star: str) -> str:
    if '"snmpwalk"' not in star and '"snmpget"' not in star:
        return star
    if "_snmp_conn" in star:  # already parameterized
        return star
    new, n = _SNMP_CONN.subn(r'\1] + _snmp_conn + [', star)
    if n == 0:
        return star
    return _re.sub(r"(def main\(ctx, params\):\n)", r"\1" + _SNMP_CONN_PREAMBLE, new, count=1)


def _sidecar_fqcn(sidecar: str, fallback: str) -> str:
    """The fqcn a pushed check registers under (its sidecar's `fqcn:`, e.g.
    checkmk.sshd_config), so we call the right tool name after pushing.

    The sidecars are YAML (checks_library reads them with yaml.safe_load), so
    parse YAML first. The previous NestedText-only parse raised on every YAML
    sidecar with a quoted/folded value (e.g. the wrapped `description:`), which
    silently fell back to `checks.<name>` — a tool the agent never registers
    (it registers the sidecar's real `checkmk.<name>`), so every assigned
    Starlark check 404'd with "check execution failed". NestedText is kept as a
    fallback for any legacy .nt sidecar."""
    import yaml

    try:
        meta = yaml.safe_load(sidecar)
        if isinstance(meta, dict) and meta.get("fqcn"):
            return str(meta["fqcn"])
    except yaml.YAMLError:
        pass
    try:
        import nestedtext

        meta = nestedtext.loads(sidecar, top="dict")
        if isinstance(meta, dict) and meta.get("fqcn"):
            return str(meta["fqcn"])
    except Exception:  # noqa: BLE001 — NestedText fallback; any parse failure → literal fallback
        pass
    return fallback


def _item_service_name(check_name: str, item: str, catalog: dict) -> str:
    """The service name for one item of a multi-item check.

    Checkmk names such a service from the plugin's `service_name` template —
    "Interface %s" -> "Interface ens18" — and the translated checks already carry
    that template verbatim in their sidecar's short_description, so it is used as
    given rather than inventing a second naming scheme. Without a placeholder the
    item is appended ("NTP Time ens18" would be wrong, but no such check is
    multi-item); without an item the name is unchanged, so existing single-service
    rows are never renamed.
    """
    if not item:
        return check_name
    template = str((catalog.get(check_name) or {}).get("short_description") or "").strip()
    if "%s" in template:
        return template % item
    return f"{template or check_name} {item}".strip()


async def evaluate_assigned_checks(
    session: AsyncSession, agent: Agent, client, checks_dir: str, *, extra_params: dict | None = None,
    perf_sink: list[dict] | None = None,
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
        # The sidecar's real format, from its extension — the checks are YAML now (legacy .nt still accepted).
        # Sending the wrong format made the agent's BuildModule parse fail, so every pushed check was silently
        # rejected and the host kept running its stale baked-in copy.
        sidecar_format = "nt" if Path(yaml_path).suffix == ".nt" else "yaml"
        deliveries.append({
            "fqcn": fqcn, "star": star, "sidecar": sidecar, "sidecar_format": sidecar_format,
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
        params = dict(getattr(ec, "parameters", {}) or {})
        try:
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
                    # Perfdata → history series, so an assigned check's metrics
                    # (chrony's offset/stratum, a DB's connection count) graph like
                    # the agent's built-in telemetry instead of being seen once and
                    # dropped. Named "<check>_<key>" so they don't collide with
                    # telemetry and the host-detail graph dialog finds them as
                    # siblings of the service's own metric (its metric field IS the
                    # check name). The item, if any, becomes a label so a multi-item
                    # check's series stay distinct. Opt-in via perf_sink (the poller
                    # owns the series write); no sink → unchanged behaviour.
                    if perf_sink is not None:
                        item = str((getattr(ec, "parameters", {}) or {}).get("item") or "").strip()
                        labels = {"item": item} if item else {}
                        for k, v in metrics.items():
                            if isinstance(v, (int, float)):
                                perf_sink.append({"metric": f"{ec.check_name}_{k}", "labels": labels, "value": float(v)})
        except Exception as exc:  # noqa: BLE001 — one bad check must not sink the cycle
            # Surface the real cause instead of swallowing it: without this the UI
            # only ever shows "check execution failed" with no way to diagnose.
            logger.exception(
                "assigned check %s failed on agent %s (item=%r): %s",
                fqcn, agent.name, params.get("item"), exc,
            )
            output = "check execution failed: %s" % exc
        # Active service checks (http/tcp/dns…) carry their display name in
        # params.service_name ("Health Qwen7b"), allowing several instances of
        # one check per host; plain checks keep the check name.
        params_of = getattr(ec, "parameters", {}) or {}
        svc_name = str(params_of.get("service_name") or "").strip() or _item_service_name(
            ec.check_name, str(params_of.get("item") or "").strip(), catalog
        )
        svc = await _upsert_service_state(
            session, agent.id, svc_name, state, value, output, now, DEFAULT_MAX_ATTEMPTS,
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
    agent_version: str
    last_seen_at: datetime | None
    state_rollup: str
    cpu_load: float | None
    mem_used_pct: float | None
    disk_used_pct_max: float | None
    service_counts: dict[str, int]


# The fleet overview only needs each host's *latest* value, which the poller
# refreshes every cycle — so bound the lookup to a recent window. Without it,
# a DISTINCT ON over the metrics *hypertable* scans all historical chunks (no
# time predicate → no chunk pruning), which made fleet_hosts take ~8s even for
# a handful of hosts. A host silent longer than this simply reads blank in the
# overview (correct: its data is stale).
_LATEST_METRIC_LOOKBACK = timedelta(hours=24)


async def _latest_metrics_by_agent(
    session: AsyncSession, agent_ids: list[UUID], metric_names: list[str]
) -> dict[tuple[UUID, str], float]:
    """Latest value per (agent, metric) for several non-mount-labeled metrics
    in ONE query (DISTINCT ON (agent_id, metric)) bounded to the recent window.
    Constraining agent_id (the caller already has the host list) lets Postgres
    use the (agent_id, metric, time) index instead of a time-ordered scan that
    filters millions of rows by metric — the ~1s→~70ms difference."""
    if not agent_ids:
        return {}
    cutoff = datetime.now(timezone.utc) - _LATEST_METRIC_LOOKBACK
    stmt = (
        select(Metric.agent_id, Metric.metric, Metric.value)
        .distinct(Metric.agent_id, Metric.metric)
        .where(Metric.agent_id.in_(agent_ids), Metric.metric.in_(metric_names), Metric.time > cutoff)
        .order_by(Metric.agent_id, Metric.metric, Metric.time.desc())
    )
    rows = (await session.execute(stmt)).all()
    return {(r.agent_id, r.metric): r.value for r in rows}


async def _latest_disk_used_pct_max(session: AsyncSession, agent_ids: list[UUID]) -> dict[UUID, float]:
    """The worst (highest) latest disk_used_pct across every mount an
    agent reports — a host with one nearly-full disk should read as
    "nearly full" on the fleet overview, not be diluted by its other,
    mostly-empty mounts. agent_id-bounded for index use (see
    _latest_metrics_by_agent)."""
    if not agent_ids:
        return {}
    mount_label = Metric.labels["mount"].astext
    cutoff = datetime.now(timezone.utc) - _LATEST_METRIC_LOOKBACK
    stmt = (
        select(Metric.agent_id, mount_label.label("mount"), Metric.value)
        .distinct(Metric.agent_id, mount_label)
        .where(Metric.agent_id.in_(agent_ids), Metric.metric == "disk_used_pct", Metric.time > cutoff)
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

    # One bounded query for all of CPU/memory (host + piggyback fallbacks),
    # plus one for disk. Piggyback hosts (Docker containers, Proxmox/vCenter
    # VMs) report CPU/memory under container_*/vm_* names, not
    # cpu_load1/mem_used_pct — fall back to those so a container/VM host isn't
    # blank in the fleet table.
    agent_ids = [a.id for a in agents]
    latest = await _latest_metrics_by_agent(
        session,
        agent_ids,
        ["cpu_load1", "mem_used_pct", "container_cpu_pct", "vm_cpu_pct", "container_mem_pct", "vm_mem_pct"],
    )
    disk_by_agent = await _latest_disk_used_pct_max(session, agent_ids)

    def _cpu(aid):
        v = latest.get((aid, "cpu_load1"))
        if v is not None:
            return v
        return latest.get((aid, "container_cpu_pct"), latest.get((aid, "vm_cpu_pct")))

    def _mem(aid):
        v = latest.get((aid, "mem_used_pct"))
        if v is not None:
            return v
        return latest.get((aid, "container_mem_pct"), latest.get((aid, "vm_mem_pct")))

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
                agent_version=agent.agent_version,
                last_seen_at=agent.last_seen_at,
                state_rollup=worst,
                cpu_load=_cpu(agent.id),
                mem_used_pct=_mem(agent.id),
                disk_used_pct_max=disk_by_agent.get(agent.id),
                service_counts=counts,
            )
        )
    return out
