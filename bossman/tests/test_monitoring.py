"""Unit tests (pure, no DB) for resolve_effective_rule/compute_state, and
real, DB-backed tests (see tests/conftest.py's db_session fixture) for
evaluate_host. Mirrors tests/test_poller.py's _make_agent/cleanup pattern.
"""

import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

from sqlalchemy import delete, select

from bossman.db.models import Agent, CheckRule, Metric, MetricRaw, MetricSeries, Service, ServiceStateHistory
from bossman.services.monitoring import (
    acknowledge_service,
    compute_availability,
    compute_state,
    evaluate_host,
    expire_acknowledgements,
    hysteresis_blocks_recovery,
    query_agent_services,
    query_problems,
    resolve_effective_rule,
    stale_after_for,
)

# ---------------------------------------------------------------------------
# resolve_effective_rule — pure, no DB


def _rule(scope_type, scope_value=None, metric="cpu_pct", created_at=None, enabled=True, rule_id=None) -> CheckRule:
    return CheckRule(
        id=rule_id or uuid.uuid4(),
        service_name="CPU load",
        metric=metric,
        comparison="gt",
        warn_threshold=80.0,
        crit_threshold=95.0,
        scope_type=scope_type,
        scope_value=scope_value,
        enabled=enabled,
        created_at=created_at or datetime.now(timezone.utc),
    )


def test_resolve_effective_rule_host_overrides_group_and_global():
    now = datetime.now(timezone.utc)
    global_rule = _rule("global", created_at=now - timedelta(hours=2))
    group_rule = _rule("group", "webservers", created_at=now - timedelta(hours=1))
    host_rule = _rule("host", "web01", created_at=now)

    result = resolve_effective_rule([global_rule, group_rule, host_rule], "web01", ["webservers"], "cpu_pct")

    assert result is host_rule


def _ou(ou_id, block_inheritance=False):
    """A minimal OU-ancestry node — resolve_effective_rule only reads .id and
    .block_inheritance off ancestry entries."""
    return SimpleNamespace(id=ou_id, block_inheritance=block_inheritance)


def _ou_rule(ou_id, metric="cpu_pct", warn=80.0, created_at=None) -> CheckRule:
    return CheckRule(
        id=uuid.uuid4(), service_name="CPU load", metric=metric, comparison="gt",
        warn_threshold=warn, crit_threshold=95.0, scope_type="ou", scope_ou_id=ou_id,
        enabled=True, created_at=created_at or datetime.now(timezone.utc),
    )


def test_resolve_effective_rule_host_overrides_ou():
    # A per-host threshold (the "own rule for this host" case) must beat the
    # OU-scoped default for the same metric — host is the closest level.
    ou = _ou("ou-prod")
    ou_rule = _ou_rule("ou-prod")
    host_rule = _rule("host", "web01")
    result = resolve_effective_rule(
        [ou_rule, host_rule], "web01", [], "cpu_pct", None, host_ou_ancestry=[ou]
    )
    assert result is host_rule


def test_resolve_effective_rule_per_label_override():
    # disk_used_pct fans out per mount. A rule pinned to one mount governs only
    # that service; other mounts fall back to the label-agnostic rule.
    agnostic = CheckRule(
        id=uuid.uuid4(), service_name="Disk", metric="disk_used_pct", comparison="gt",
        warn_threshold=80.0, crit_threshold=90.0, scope_type="host", scope_value="web01",
        label_value=None, enabled=True, created_at=datetime.now(timezone.utc),
    )
    for_data1 = CheckRule(
        id=uuid.uuid4(), service_name="Disk", metric="disk_used_pct", comparison="gt",
        warn_threshold=50.0, crit_threshold=60.0, scope_type="host", scope_value="web01",
        label_value="/data1", enabled=True, created_at=datetime.now(timezone.utc),
    )
    rules = [agnostic, for_data1]
    assert resolve_effective_rule(rules, "web01", [], "disk_used_pct", "/data1") is for_data1
    assert resolve_effective_rule(rules, "web01", [], "disk_used_pct", "/var") is agnostic


def test_resolve_effective_rule_group_overrides_global():
    global_rule = _rule("global")
    group_rule = _rule("group", "webservers")

    result = resolve_effective_rule([global_rule, group_rule], "web01", ["webservers"], "cpu_pct")

    assert result is group_rule


def test_resolve_effective_rule_falls_back_to_global_when_no_host_or_group_rule_matches():
    global_rule = _rule("global")
    unrelated_group_rule = _rule("group", "dbservers")

    result = resolve_effective_rule([global_rule, unrelated_group_rule], "web01", ["webservers"], "cpu_pct")

    assert result is global_rule


def test_resolve_effective_rule_nested_group_child_matches_parent_rule():
    """Block K2b ("nested host groups"): a rule scoped to "Europe" also
    governs a host tagged "Europe/Latvia" — slash-notation subgroup
    inheritance, matched at CheckRule-evaluation time (groups are still a
    flat tag list on Agent, no separate hierarchy object)."""
    parent_rule = _rule("group", "Europe")

    result = resolve_effective_rule([parent_rule], "riga01", ["Europe/Latvia"], "cpu_pct")

    assert result is parent_rule


def test_resolve_effective_rule_nested_group_does_not_match_unrelated_sibling():
    # "Europe" must not match a host tagged "Europe2" or "EuropeWest" —
    # only an exact segment boundary ("Europe" itself or "Europe/...").
    parent_rule = _rule("group", "Europe")

    result = resolve_effective_rule([parent_rule], "us01", ["Europe2", "EuropeWest"], "cpu_pct")

    assert result is None


def test_resolve_effective_rule_nested_group_more_specific_subgroup_wins():
    # Both rules match a host tagged "Europe/Latvia"; the deeper/more
    # specific one wins regardless of creation order.
    now = datetime.now(timezone.utc)
    parent_rule = _rule("group", "Europe", created_at=now)  # newer, but less specific
    child_rule = _rule("group", "Europe/Latvia", created_at=now - timedelta(hours=1))

    result = resolve_effective_rule([parent_rule, child_rule], "riga01", ["Europe/Latvia"], "cpu_pct")

    assert result is child_rule


def test_resolve_effective_rule_ties_broken_by_most_recently_created():
    now = datetime.now(timezone.utc)
    older_group_rule = _rule("group", "webservers", created_at=now - timedelta(hours=1))
    newer_group_rule = _rule("group", "webservers", created_at=now)

    result = resolve_effective_rule([older_group_rule, newer_group_rule], "web01", ["webservers"], "cpu_pct")

    assert result is newer_group_rule


def test_resolve_effective_rule_ignores_disabled_rules():
    disabled_host_rule = _rule("host", "web01", enabled=False)
    global_rule = _rule("global")

    result = resolve_effective_rule([disabled_host_rule, global_rule], "web01", [], "cpu_pct")

    assert result is global_rule


def test_resolve_effective_rule_ignores_rules_for_a_different_metric():
    rule = _rule("global", metric="mem_pct")

    result = resolve_effective_rule([rule], "web01", [], "cpu_pct")

    assert result is None


def test_resolve_effective_rule_returns_none_when_nothing_matches():
    group_rule = _rule("group", "dbservers")
    host_rule = _rule("host", "db02")

    result = resolve_effective_rule([group_rule, host_rule], "web01", ["webservers"], "cpu_pct")

    assert result is None


# ---------------------------------------------------------------------------
# compute_state — pure, no DB


def test_compute_state_ok_when_within_thresholds():
    state, output = compute_state("gt", 50.0, warn=80.0, crit=95.0)
    assert state == "OK"
    assert "50" in output


def test_compute_state_formats_value_with_unit_and_rounding():
    # A raw float like 0.36648034236027804 on a *_pct metric renders as 0.37%,
    # not the full float repr (the service-summary units bug).
    state, output = compute_state("gt", 0.36648034236027804, warn=80.0, crit=95.0, metric="disk_used_pct")
    assert state == "OK"
    assert "0.37%" in output
    assert "0.36648" not in output


def test_format_value_units():
    from bossman.services.monitoring import format_value

    assert format_value(0.10023, "cpu_load") == "0.1"        # unitless, rounded
    assert format_value(21.16248, "mem_used_pct") == "21.16%"
    assert format_value(512.0, "mem_used_mib") == "512 MiB"
    assert format_value(None, "x") == "n/a"


def test_compute_state_warn_when_over_warn_threshold():
    state, _ = compute_state("gt", 85.0, warn=80.0, crit=95.0)
    assert state == "WARN"


def test_compute_state_crit_when_over_crit_threshold():
    state, _ = compute_state("gt", 99.0, warn=80.0, crit=95.0)
    assert state == "CRIT"


def test_compute_state_crit_takes_precedence_over_warn():
    # A value tripping both thresholds is CRIT, not WARN.
    state, _ = compute_state("gt", 99.0, warn=1.0, crit=1.0)
    assert state == "CRIT"


def test_compute_state_unknown_when_no_value():
    state, output = compute_state("gt", None, warn=80.0, crit=95.0)
    assert state == "UNKNOWN"
    assert "no recent" in output


def test_compute_state_lt_comparison():
    state, _ = compute_state("lt", 5.0, warn=10.0, crit=2.0)
    assert state == "WARN"


def test_compute_state_none_threshold_never_trips():
    state, _ = compute_state("gt", 1_000_000.0, warn=None, crit=None)
    assert state == "OK"


def test_hysteresis_blocks_recovery_gt_style():
    # warn=80, recovery=70: a value of 75 is under warn but still above the
    # stricter recovery threshold — hysteresis says "not recovered yet".
    assert hysteresis_blocks_recovery("gt", 75.0, 70.0) is True
    assert hysteresis_blocks_recovery("gt", 65.0, 70.0) is False


def test_hysteresis_blocks_recovery_lt_style():
    # A "disk free < 10 is bad" rule with recovery=15: 12 is above the
    # problem threshold but still below the stricter recovery threshold.
    assert hysteresis_blocks_recovery("lt", 12.0, 15.0) is True
    assert hysteresis_blocks_recovery("lt", 18.0, 15.0) is False


# ---------------------------------------------------------------------------
# evaluate_host — real DB


async def _make_agent(db_session, **overrides) -> Agent:
    name = f"mon-{uuid.uuid4().hex[:8]}"
    fields = {"name": name, "token": "tok", "mode": "standalone", "enrollment_state": "enrolled"}
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _make_rule(db_session, **overrides) -> CheckRule:
    fields = {
        "service_name": "CPU load",
        "metric": "cpu_pct",
        "comparison": "gt",
        "warn_threshold": 80.0,
        "crit_threshold": 95.0,
        "scope_type": "global",
        "scope_value": None,
        "enabled": True,
    }
    fields.update(overrides)
    rule = CheckRule(**fields)
    db_session.add(rule)
    await db_session.flush()
    await db_session.commit()
    return rule


async def _write_metric(db_session, agent, metric, value, when=None, labels=None):
    """Writes through metric_series + metrics_raw, because `metrics` is a VIEW.

    It used to insert into Metric directly. Since metrics became a view over
    (metric_series JOIN metrics_raw), every DB-backed test in this file failed with
    "cannot insert into view metrics" — including plain
    test_evaluate_host_creates_service_with_ok_state, i.e. the breakage was total and
    silent in the suite's noise, not specific to any one test.
    """
    series = await db_session.scalar(
        select(MetricSeries).where(
            MetricSeries.agent_id == agent.id,
            MetricSeries.metric == metric,
            MetricSeries.labels == (labels or {}),
        )
    )
    if series is None:
        series = MetricSeries(agent_id=agent.id, metric=metric, labels=labels or {})
        db_session.add(series)
        await db_session.flush()
    db_session.add(MetricRaw(series_id=series.series_id, time=when or datetime.now(timezone.utc), value=value))
    await db_session.flush()
    await db_session.commit()


async def _cleanup(db_session, agent, *rules):
    services = (await db_session.scalars(select(Service).where(Service.agent_id == agent.id))).all()
    for s in services:
        await db_session.delete(s)
    await db_session.flush()
    history = (await db_session.scalars(select(ServiceStateHistory).where(ServiceStateHistory.agent_id == agent.id))).all()
    for h in history:
        await db_session.delete(h)
    # metrics is a view: delete the raw rows, then the series that own them.
    series_ids = list(
        (await db_session.scalars(select(MetricSeries.series_id).where(MetricSeries.agent_id == agent.id))).all()
    )
    if series_ids:
        await db_session.execute(delete(MetricRaw).where(MetricRaw.series_id.in_(series_ids)))
        await db_session.execute(delete(MetricSeries).where(MetricSeries.series_id.in_(series_ids)))
    await db_session.flush()
    for rule in rules:
        got = await db_session.get(CheckRule, rule.id)
        if got is not None:
            await db_session.delete(got)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def test_evaluate_host_creates_service_with_ok_state(db_session):
    agent = await _make_agent(db_session)
    rule = await _make_rule(db_session)
    await _write_metric(db_session, agent, "cpu_pct", 50.0)

    services = await evaluate_host(db_session, agent)
    await db_session.commit()

    assert len(services) == 1
    assert services[0].name == "CPU load"
    assert services[0].state == "OK"
    assert services[0].value == 50.0

    await _cleanup(db_session, agent, rule)


async def test_evaluate_host_records_history_on_state_change(db_session):
    agent = await _make_agent(db_session)
    rule = await _make_rule(db_session, max_attempts=1)
    await _write_metric(db_session, agent, "cpu_pct", 50.0)

    await evaluate_host(db_session, agent)
    await db_session.commit()

    await _write_metric(db_session, agent, "cpu_pct", 99.0)
    await evaluate_host(db_session, agent)
    await db_session.commit()

    service = await db_session.scalar(select(Service).where(Service.agent_id == agent.id))
    assert service.state == "CRIT"

    history = (
        await db_session.scalars(
            select(ServiceStateHistory).where(ServiceStateHistory.agent_id == agent.id).order_by(ServiceStateHistory.time)
        )
    ).all()
    assert [h.state for h in history] == ["OK", "CRIT"]

    await _cleanup(db_session, agent, rule)


async def test_evaluate_host_does_not_record_history_when_state_unchanged(db_session):
    agent = await _make_agent(db_session)
    rule = await _make_rule(db_session, max_attempts=1)
    await _write_metric(db_session, agent, "cpu_pct", 50.0)
    await evaluate_host(db_session, agent)
    await db_session.commit()

    await _write_metric(db_session, agent, "cpu_pct", 55.0)  # still OK
    await evaluate_host(db_session, agent)
    await db_session.commit()

    history = (await db_session.scalars(select(ServiceStateHistory).where(ServiceStateHistory.agent_id == agent.id))).all()
    assert len(history) == 1  # only the initial OK, not a second one

    await _cleanup(db_session, agent, rule)


async def test_evaluate_host_clears_acknowledgement_on_state_change(db_session):
    agent = await _make_agent(db_session)
    rule = await _make_rule(db_session, max_attempts=1)
    await _write_metric(db_session, agent, "cpu_pct", 99.0)
    await evaluate_host(db_session, agent)
    await db_session.commit()

    service = await db_session.scalar(select(Service).where(Service.agent_id == agent.id))
    service.acknowledged = True
    service.ack_comment = "known issue"
    service.ack_by = "admin"
    await db_session.commit()

    await _write_metric(db_session, agent, "cpu_pct", 50.0)  # recovers to OK
    await evaluate_host(db_session, agent)
    await db_session.commit()

    service = await db_session.scalar(select(Service).where(Service.agent_id == agent.id))
    assert service.state == "OK"
    assert service.acknowledged is False
    assert service.ack_comment is None

    await _cleanup(db_session, agent, rule)


async def test_evaluate_host_host_rule_overrides_group_rule_for_real(db_session):
    agent = await _make_agent(db_session, groups=["webservers"])
    group_rule = await _make_rule(db_session, scope_type="group", scope_value="webservers", warn_threshold=10.0, crit_threshold=20.0)
    host_rule = await _make_rule(db_session, scope_type="host", scope_value=agent.name, warn_threshold=80.0, crit_threshold=95.0)
    await _write_metric(db_session, agent, "cpu_pct", 50.0)

    services = await evaluate_host(db_session, agent)
    await db_session.commit()

    # Under the group rule (warn=10) this would be WARN; the host rule
    # (warn=80) says OK — proves the host override actually took effect.
    assert services[0].state == "OK"
    assert services[0].rule_id == host_rule.id

    await _cleanup(db_session, agent, group_rule, host_rule)


async def test_evaluate_host_unknown_when_no_metric_ever_polled(db_session):
    agent = await _make_agent(db_session)
    rule = await _make_rule(db_session)

    services = await evaluate_host(db_session, agent)
    await db_session.commit()

    assert services[0].state == "UNKNOWN"
    assert services[0].value is None

    await _cleanup(db_session, agent, rule)


async def test_evaluate_host_no_rules_produces_no_services(db_session):
    agent = await _make_agent(db_session)

    services = await evaluate_host(db_session, agent)

    assert services == []

    await db_session.delete(agent)
    await db_session.commit()


async def test_soft_then_hard_debounce_and_problems_filter(db_session):
    """Block H7: a fresh non-OK result is soft (not a problem) until it has
    recurred max_attempts times, then hard (a real problem). query_problems
    only surfaces hard states."""
    agent = await _make_agent(db_session)
    rule = await _make_rule(db_session, max_attempts=3)  # 3 consecutive CRITs → hard

    for expected_type, expected_attempt in [("soft", 1), ("soft", 2), ("hard", 3), ("hard", 3)]:
        await _write_metric(db_session, agent, "cpu_pct", 99.0)
        await evaluate_host(db_session, agent)
        await db_session.commit()
        svc = await db_session.scalar(select(Service).where(Service.agent_id == agent.id))
        assert svc.state == "CRIT"
        assert (svc.state_type, svc.attempt) == (expected_type, expected_attempt)
        problems = await query_problems(db_session)
        mine = [p for p in problems if p.service.agent_id == agent.id]
        # A soft problem is NOT surfaced; a hard one is.
        assert (len(mine) == 1) == (expected_type == "hard")

    # Exactly one history row — the single hard onset, no soft churn.
    history = (await db_session.scalars(select(ServiceStateHistory).where(ServiceStateHistory.agent_id == agent.id))).all()
    assert [h.state for h in history] == ["CRIT"]

    await _cleanup(db_session, agent, rule)


async def test_hysteresis_holds_state_until_recovery_threshold_cleared(db_session):
    """Block K6: with recovery_threshold set, a value that dips back under
    warn_threshold but hasn't cleared the stricter recovery threshold holds
    at the previous problem state instead of flipping to OK."""
    agent = await _make_agent(db_session)
    rule = await _make_rule(db_session, max_attempts=1, warn_threshold=80.0, crit_threshold=95.0, recovery_threshold=70.0)

    await _write_metric(db_session, agent, "cpu_pct", 90.0)  # WARN (immediately hard, max_attempts=1)
    await evaluate_host(db_session, agent)
    await db_session.commit()
    svc = await db_session.scalar(select(Service).where(Service.agent_id == agent.id))
    assert svc.state == "WARN"

    await _write_metric(db_session, agent, "cpu_pct", 75.0)  # under warn(80) but still above recovery(70)
    await evaluate_host(db_session, agent)
    await db_session.commit()
    await db_session.refresh(svc)
    assert svc.state == "WARN"  # held, not recovered yet

    await _write_metric(db_session, agent, "cpu_pct", 65.0)  # now clears recovery(70)
    await evaluate_host(db_session, agent)
    await db_session.commit()
    await db_session.refresh(svc)
    assert svc.state == "OK"

    await _cleanup(db_session, agent, rule)


async def test_evaluate_host_stamps_agent_tags_for_notification_routing(db_session):
    """Block K7: evaluate_host stamps the host's tags onto the transient
    _notify_agent_tags attribute, the same way it already stamps
    _notify_agent_name — collect_and_dispatch reads both to build a
    NotifyEvent for NotificationRule.tag_filter matching."""
    agent = await _make_agent(db_session, tags={"env": "prod"})
    rule = await _make_rule(db_session, max_attempts=1)
    await _write_metric(db_session, agent, "cpu_pct", 99.0)

    updated = await evaluate_host(db_session, agent)
    await db_session.commit()

    assert len(updated) == 1
    assert getattr(updated[0], "_notify_agent_tags", None) == {"env": "prod"}

    await _cleanup(db_session, agent, rule)


async def test_composite_condition_and_logic_requires_both_metrics_to_trip(db_session):
    """Block K9: condition_logic="AND" (the default) only fires CRIT when
    BOTH the primary metric and every extra condition trip their crit
    threshold — one alone (e.g. CPU high but load1 normal) stays OK."""
    agent = await _make_agent(db_session)
    rule = await _make_rule(
        db_session,
        metric="cpu_pct",
        max_attempts=1,
        warn_threshold=80.0,
        crit_threshold=95.0,
        extra_conditions=[{"metric": "load1", "comparison": "gt", "warn_threshold": 4.0, "crit_threshold": 8.0}],
        condition_logic="AND",
    )

    # CPU is CRIT-high but load1 is normal — AND requires both.
    await _write_metric(db_session, agent, "cpu_pct", 99.0)
    await _write_metric(db_session, agent, "load1", 1.0)
    updated = await evaluate_host(db_session, agent)
    await db_session.commit()
    assert updated[0].state == "OK"

    # Now load1 also trips — both conditions true, AND -> CRIT.
    await _write_metric(db_session, agent, "load1", 9.0)
    updated = await evaluate_host(db_session, agent)
    await db_session.commit()
    assert updated[0].state == "CRIT"
    assert "composite (AND) CRIT" in updated[0].output

    await _cleanup(db_session, agent, rule)


async def test_composite_condition_or_logic_fires_on_either_metric(db_session):
    """Block K9: condition_logic="OR" fires CRIT if EITHER the primary or
    an extra condition trips, even when the other is completely normal."""
    agent = await _make_agent(db_session)
    rule = await _make_rule(
        db_session,
        metric="cpu_pct",
        max_attempts=1,
        warn_threshold=80.0,
        crit_threshold=95.0,
        extra_conditions=[{"metric": "load1", "comparison": "gt", "warn_threshold": 4.0, "crit_threshold": 8.0}],
        condition_logic="OR",
    )

    await _write_metric(db_session, agent, "cpu_pct", 10.0)  # nowhere near CPU thresholds
    await _write_metric(db_session, agent, "load1", 9.0)  # but load1 alone trips CRIT
    updated = await evaluate_host(db_session, agent)
    await db_session.commit()
    assert updated[0].state == "CRIT"

    await _cleanup(db_session, agent, rule)


async def test_composite_condition_skipped_when_primary_metric_unknown(db_session):
    """Block K9: a composite rule stays UNKNOWN (not silently evaluated
    against just the extra conditions) when its own primary metric has
    never been sampled."""
    agent = await _make_agent(db_session)
    rule = await _make_rule(
        db_session,
        metric="cpu_pct",
        max_attempts=1,
        extra_conditions=[{"metric": "load1", "comparison": "gt", "crit_threshold": 8.0}],
        condition_logic="OR",
    )
    await _write_metric(db_session, agent, "load1", 9.0)  # primary (cpu_pct) never written

    updated = await evaluate_host(db_session, agent)
    await db_session.commit()

    assert updated[0].state == "UNKNOWN"

    await _cleanup(db_session, agent, rule)


async def test_multi_label_series_collapse_to_one_service_and_keep_notify(db_session):
    """Regression (Block H8): a mount-less metric with several label-sets
    must upsert its single service exactly once per pass and keep the
    hard-onset notify intent — not process it twice, the second pass
    clobbering _notify_event to None."""
    agent = await _make_agent(db_session)
    rule = await _make_rule(db_session, service_name="Memory", metric="mem_used_pct", comparison="ge",
                            warn_threshold=10.0, crit_threshold=20.0, max_attempts=1)
    # Two distinct label-sets, neither a mount — both map to service "Memory".
    await _write_metric(db_session, agent, "mem_used_pct", 95.0, labels={"src": "pull"})
    await _write_metric(db_session, agent, "mem_used_pct", 96.0, labels={"src": "snapshot"})

    touched = await evaluate_host(db_session, agent)
    await db_session.commit()

    mem = [s for s in touched if s.name == "Memory"]
    assert len(mem) == 1, "one service, not one-per-label"
    assert mem[0].state == "CRIT"
    assert getattr(mem[0], "_notify_event", None) == "problem", "hard onset notify intent survives"

    services = (await db_session.scalars(select(Service).where(Service.agent_id == agent.id))).all()
    assert len(services) == 1

    await _cleanup(db_session, agent, rule)


async def test_flapping_flag_set_on_frequent_changes(db_session):
    """Block H7: a service that changes hard state many times in the window
    gets is_flapping set."""
    agent = await _make_agent(db_session)
    rule = await _make_rule(db_session, max_attempts=1)  # every change is immediately hard

    for value in [99.0, 10.0, 99.0, 10.0, 99.0, 10.0]:
        await _write_metric(db_session, agent, "cpu_pct", value)
        await evaluate_host(db_session, agent)
        await db_session.commit()

    svc = await db_session.scalar(select(Service).where(Service.agent_id == agent.id))
    assert svc.is_flapping is True

    await _cleanup(db_session, agent, rule)


async def test_disk_rule_fans_out_per_mount_with_override(db_session):
    """A label-agnostic disk rule (Block H6) grades every mount as its own
    'Disk <mount>' service; a mount-pinned rule overrides just that mount."""
    agent = await _make_agent(db_session)
    # 3 mounts, one dangerously full.
    await _write_metric(db_session, agent, "disk_used_pct", 10.0, labels={"mount": "/"})
    await _write_metric(db_session, agent, "disk_used_pct", 85.0, labels={"mount": "/var"})
    await _write_metric(db_session, agent, "disk_used_pct", 40.0, labels={"mount": "/home"})
    # Global default: warn 80 / crit 90 → /var is WARN.
    default_rule = await _make_rule(
        db_session, service_name="Disk", metric="disk_used_pct", comparison="ge", warn_threshold=80.0, crit_threshold=90.0
    )
    # Mount-pinned override for /var: warn 95 → /var back to OK.
    override = await _make_rule(
        db_session,
        service_name="Disk",
        metric="disk_used_pct",
        comparison="ge",
        warn_threshold=95.0,
        crit_threshold=99.0,
        label_value="/var",
    )

    await evaluate_host(db_session, agent)
    await db_session.commit()

    services = {s.name: s for s in (await db_session.scalars(select(Service).where(Service.agent_id == agent.id))).all()}
    assert set(services) == {"Disk /", "Disk /var", "Disk /home"}, "one service per mount"
    assert services["Disk /"].state == "OK"
    assert services["Disk /home"].state == "OK"
    assert services["Disk /var"].state == "OK", "the /var-pinned override (warn 95) beats the global default (warn 80)"

    await _cleanup(db_session, agent, default_rule, override)


async def test_ingest_agent_check_yields_to_owning_rule(db_session):
    """Rule authority (Block H6): once a rule owns a service by name, the
    agent's built-in reading for that name is ignored (no fight)."""
    agent = await _make_agent(db_session)
    rule = await _make_rule(
        db_session, service_name="Memory", metric="mem_used_pct", comparison="ge", warn_threshold=80.0, crit_threshold=90.0
    )
    await _write_metric(db_session, agent, "mem_used_pct", 50.0)  # OK per the rule
    await evaluate_host(db_session, agent)
    await db_session.commit()

    # The agent now reports "Memory" as CRITICAL — but the rule owns it.
    from bossman.services.monitoring import ingest_agent_checks

    await ingest_agent_checks(db_session, agent, [{"name": "Memory", "status": "CRITICAL", "message": "agent says crit"}])
    await db_session.commit()

    service = await db_session.scalar(select(Service).where(Service.agent_id == agent.id, Service.name == "Memory"))
    assert service.state == "OK", "the rule's grading wins; the agent's built-in reading is ignored"
    assert service.rule_id == rule.id

    await _cleanup(db_session, agent, rule)


async def test_seed_default_check_rules_is_idempotent(db_session):
    from bossman.services.monitoring import seed_default_check_rules

    # Clear any rules first so the count is deterministic in the shared DB.
    for r in (await db_session.scalars(select(CheckRule))).all():
        await db_session.delete(r)
    await db_session.commit()

    first = await seed_default_check_rules(db_session)
    second = await seed_default_check_rules(db_session)
    assert first == 2 and second == 0, "seeds Memory+Disk once, then no-ops"
    rules = (await db_session.scalars(select(CheckRule).where(CheckRule.is_default == True))).all()  # noqa: E712
    assert {r.service_name for r in rules} == {"Memory", "Disk"}

    for r in rules:
        await db_session.delete(r)
    await db_session.commit()


async def test_timed_acknowledgement_expires(db_session):
    """A timed ack (Block H5): still handled before expiry, lapses after —
    and query_agent_services (a read path) applies the expiry lazily."""
    from datetime import timedelta

    agent = await _make_agent(db_session)
    rule = await _make_rule(db_session)
    await _write_metric(db_session, agent, "cpu_pct", 99.0)
    await evaluate_host(db_session, agent)
    await db_session.commit()
    service = await db_session.scalar(select(Service).where(Service.agent_id == agent.id))

    now = datetime.now(timezone.utc)
    # Ack that already expired a minute ago.
    await acknowledge_service(db_session, service.id, "short ack", "admin", expires_at=now - timedelta(minutes=1))
    await db_session.refresh(service)
    assert service.acknowledged is True and service.ack_expires_at is not None

    # A read path lazily expires it: the service comes back unacknowledged.
    views = await query_agent_services(db_session, agent.id)
    assert views[0].service.acknowledged is False
    assert views[0].service.ack_expires_at is None

    # A future expiry stays acknowledged.
    await acknowledge_service(db_session, service.id, "longer ack", "admin", expires_at=now + timedelta(hours=1))
    n = await expire_acknowledgements(db_session, now)
    assert n == 0
    await db_session.refresh(service)
    assert service.acknowledged is True

    await _cleanup(db_session, agent, rule)


# ---------------------------------------------------------------------------
# compute_availability — Block H9 SLA report


async def _hist(db_session, agent, name, when, state):
    db_session.add(ServiceStateHistory(time=when, agent_id=agent.id, service_name=name, state=state, value=None))
    await db_session.flush()
    await db_session.commit()


async def test_compute_availability_splits_time_in_state(db_session):
    """A CRIT that lasted a quarter of the window yields ok_percent≈75,
    reconstructed from the hard-state timeline plus the tail to `end`."""
    agent = await _make_agent(db_session)
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=4)
    # OK for 3h, CRIT for the last 1h (25%).
    await _hist(db_session, agent, "CPU", start, "OK")
    await _hist(db_session, agent, "CPU", end - timedelta(hours=1), "CRIT")

    report = await compute_availability(db_session, agent.id, "CPU", start, end)
    ok = next(s for s in report.slices if s.state == "OK")
    crit = next(s for s in report.slices if s.state == "CRIT")
    assert abs(report.ok_percent - 75.0) < 0.01
    assert abs(ok.percent - 75.0) < 0.01
    assert abs(crit.percent - 25.0) < 0.01
    assert abs(report.monitored_seconds - 4 * 3600) < 1.0
    assert report.state_changes == 2

    await _cleanup(db_session, agent)


async def test_compute_availability_carry_in_from_before_window(db_session):
    """A state recorded before `start` (carry-in) covers the leading span —
    a service CRIT since before the window is 100% CRIT within it."""
    agent = await _make_agent(db_session)
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=2)
    await _hist(db_session, agent, "Disk", start - timedelta(hours=5), "CRIT")

    report = await compute_availability(db_session, agent.id, "Disk", start, end)
    crit = next(s for s in report.slices if s.state == "CRIT")
    assert abs(crit.percent - 100.0) < 0.01
    assert report.ok_percent == 0.0
    assert report.state_changes == 0

    await _cleanup(db_session, agent)


async def test_compute_availability_leading_gap_is_unmonitored(db_session):
    """No record before the first in-window change: the leading span is left
    uncounted (monitored < wall window), not charged as downtime."""
    agent = await _make_agent(db_session)
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=4)
    # First-ever record 1h into the window; OK from there on.
    await _hist(db_session, agent, "Mem", start + timedelta(hours=1), "OK")

    report = await compute_availability(db_session, agent.id, "Mem", start, end)
    assert abs(report.monitored_seconds - 3 * 3600) < 1.0
    assert abs(report.window_seconds - 4 * 3600) < 1.0
    assert abs(report.ok_percent - 100.0) < 0.01

    await _cleanup(db_session, agent)


# render helpers (Checkmk-ported) + uptime/cpu formatting


def test_render_timespan_and_units():
    from bossman.services import render

    assert render.timespan(1046258) == "12 days 2 hours"
    assert render.timespan(90) == "1 minute 30 seconds"
    assert render.percent(0.366) == "0.37%"
    assert render.percent(0.0) == "0%"
    assert render.bytes(536870912) == "512 MiB"
    assert render.number(0.0668) == "0.07"


def test_cpu_load_is_not_percent():
    from bossman.services.monitoring import format_value

    # cpu_pct carries a load average despite the name — no % sign.
    assert format_value(0.0668, "cpu_pct") == "0.07"
    assert "%" not in format_value(0.0668, "cpu_pct")


def test_summary_drops_value_prefix_and_uses_symbol():
    from bossman.services.monitoring import compute_state

    _, ok = compute_state("gt", 0.366, 80, 95, metric="disk_used_pct")
    assert ok == "0.37% within thresholds"
    assert not ok.startswith("value")
    _, crit = compute_state("ge", 27.56, 15, 20, metric="mem_used_pct")
    assert crit == "27.56% ≥ crit 20.00%"


# ---------------------------------------------------------------------------
# L1 — an aged-out reading must not be re-confirmed as a verdict about now


class _StaleSettings:
    staleness_factor = 4.0
    poll_interval_seconds = 60


def _only(services, name):
    """The one service with this name, asserting it is unambiguous."""
    hits = [s for s in services if s.name == name]
    assert len(hits) == 1, f"expected exactly one {name!r}, got {[s.name for s in services]}"
    return hits[0]


async def test_evaluate_host_reports_no_data_instead_of_the_last_known_value(db_session):
    """The regression, end to end: a value older than the window goes UNKNOWN.

    Before this, a host silent for 26 days kept reporting OK — evaluate_host runs even
    when the host was not reached, and the value was fetched with no age bound at all.
    """
    agent = await _make_agent(db_session)
    rule = await _make_rule(db_session)
    old = datetime.now(timezone.utc) - timedelta(days=26)
    await _write_metric(db_session, agent, "cpu_pct", 50.0, when=old)

    services = await evaluate_host(db_session, agent, stale_after=stale_after_for(_StaleSettings()))
    await db_session.commit()

    # By name, not by index: other globally-scoped rules may exist in the database,
    # and this test is about one service's verdict, not about how many there are.
    cpu = _only(services, "CPU load")
    assert cpu.state == "UNKNOWN", "a 26-day-old sample must not be judged"
    assert cpu.output.startswith("no data for ")
    assert cpu.value is None, "the stale number must not be shown as current either"

    await _cleanup(db_session, agent, rule)


async def test_evaluate_host_still_judges_a_fresh_value(db_session):
    """The other half: normal operation must not be turned into UNKNOWN."""
    agent = await _make_agent(db_session)
    rule = await _make_rule(db_session)
    await _write_metric(
        db_session, agent, "cpu_pct", 99.0, when=datetime.now(timezone.utc) - timedelta(seconds=100)
    )

    services = await evaluate_host(db_session, agent, stale_after=stale_after_for(_StaleSettings()))
    await db_session.commit()

    cpu = _only(services, "CPU load")
    assert cpu.state == "CRIT", "100 s is within the measured healthy range"
    assert cpu.value == 99.0

    await _cleanup(db_session, agent, rule)


async def test_stale_fan_out_keeps_its_mount_identity(db_session):
    """"Disk /" must go UNKNOWN as "Disk /", not collapse into a nameless "Disk".

    This is the subtle half of the fix. Simply filtering aged-out rows out of the query
    would leave no labelled series, the code would fall through to its single
    label-less entry, and a NEW "Disk" service would appear UNKNOWN while the real
    "Disk /" and "Disk /var" rows kept their last OK forever — the exact bug, now with
    an extra service to hide it.
    """
    agent = await _make_agent(db_session)
    rule = await _make_rule(db_session, service_name="Disk", metric="disk_used_pct")
    old = datetime.now(timezone.utc) - timedelta(days=3)
    await _write_metric(db_session, agent, "disk_used_pct", 41.0, when=old, labels={"mount": "/"})
    await _write_metric(db_session, agent, "disk_used_pct", 62.0, when=old, labels={"mount": "/var"})

    services = await evaluate_host(db_session, agent, stale_after=stale_after_for(_StaleSettings()))
    await db_session.commit()

    disks = sorted(s.name for s in services if s.name.startswith("Disk /"))
    assert disks == ["Disk /", "Disk /var"], f"identity lost: {disks}"
    assert {s.state for s in services if s.name.startswith("Disk /")} == {"UNKNOWN"}

    await _cleanup(db_session, agent, rule)


async def test_same_timestamp_label_series_stay_distinct_objects(db_session):
    """Two series written at the IDENTICAL timestamp must not fold into one row.

    The agent stamps every point of a sampling tick with the same `now`, so on vpp0221
    all five disk_used_pct mounts carry 15:05:25.000000. Metric is mapped onto the
    `metrics` VIEW, and while its mapped key was (time, agent_id, metric) — labels
    excluded — SQLAlchemy's identity map folded those five into ONE object: the query
    returned five results that were the same Python object five times, all claiming
    mount "/". evaluate_host keys its per-mount dict off exactly that, so four of five
    filesystems went unchecked while looking monitored (the agent's own checks write
    services under the same names).

    Asserted on object identity, not just on the mount list, because that is the actual
    failure: the SQL was always right — the same query without the ORM entity returned
    all five mounts.
    """
    agent = await _make_agent(db_session)
    when = datetime.now(timezone.utc)
    for mount, value in (("/", 41.0), ("/var", 62.0), ("/rpool", 3.0)):
        await _write_metric(db_session, agent, "disk_used_pct", value, when=when, labels={"mount": mount})

    rows = (
        await db_session.scalars(
            select(Metric)
            .where(Metric.agent_id == agent.id, Metric.metric == "disk_used_pct")
            .order_by(Metric.labels, Metric.time.desc())
            .distinct(Metric.labels)
        )
    ).all()

    assert len({id(r) for r in rows}) == 3, "the identity map folded distinct series into one object"
    assert sorted((r.labels or {}).get("mount") for r in rows) == ["/", "/rpool", "/var"]
    assert sorted(r.value for r in rows) == [3.0, 41.0, 62.0], "values must follow their own mount"

    await _cleanup(db_session, agent)
