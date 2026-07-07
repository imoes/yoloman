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


async def _write_metric(db_session, agent, metric, value, when=None):
    db_session.add(Metric(time=when or datetime.now(timezone.utc), agent_id=agent.id, metric=metric, value=value, labels={}))
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
    rule = await _make_rule(db_session)
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
    rule = await _make_rule(db_session)
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
    rule = await _make_rule(db_session)
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
