"""Unit tests (pure, no DB) for resolve_effective_rule/compute_state, and
real, DB-backed tests (see tests/conftest.py's db_session fixture) for
evaluate_host. Mirrors tests/test_poller.py's _make_agent/cleanup pattern.
"""

import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from bossman.db.models import Agent, CheckRule, Metric, Service, ServiceStateHistory
from bossman.services.monitoring import (
    acknowledge_service,
    compute_state,
    evaluate_host,
    expire_acknowledgements,
    query_agent_services,
    query_problems,
    resolve_effective_rule,
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
    assert "50.0" in output


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
    db_session.add(
        Metric(time=when or datetime.now(timezone.utc), agent_id=agent.id, metric=metric, value=value, labels=labels or {})
    )
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
    metrics = (await db_session.scalars(select(Metric).where(Metric.agent_id == agent.id))).all()
    for m in metrics:
        await db_session.delete(m)
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
