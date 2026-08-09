"""Tests for services/notification.py (Block H8): rule matching, rendering,
dispatch with injected fake senders (no real SMTP/HTTP), and the
ack/downtime/flapping suppression in collect_and_dispatch."""

import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from bossman.config import Settings
from bossman.db.models import Agent, CheckRule, Downtime, Notification, NotificationRule, Service
from bossman.services import notification
from bossman.services.notification import NotifyEvent, rule_matches, tags_match


def _rule(**kw):
    fields = dict(
        name="r", enabled=True, on_problem=True, on_recovery=True, min_state="WARN",
        host_filter=None, service_filter=None, channel="email", target="ops@example.com", tag_filter=None,
    )
    fields.update(kw)
    return NotificationRule(**fields)


def _ev(state="CRIT", event="problem", host="web01", service="Memory", tags=None):
    return NotifyEvent(agent_name=host, service_name=service, state=state, event=event, output="x", agent_tags=tags or {})


def test_rule_matches_severity_and_events():
    assert rule_matches(_rule(min_state="WARN"), _ev(state="CRIT")) is True
    assert rule_matches(_rule(min_state="CRIT"), _ev(state="WARN")) is False  # below floor
    assert rule_matches(_rule(on_problem=False), _ev(event="problem")) is False
    assert rule_matches(_rule(on_recovery=False), _ev(event="recovery")) is False
    # recovery ignores the severity floor
    assert rule_matches(_rule(min_state="CRIT"), _ev(state="OK", event="recovery")) is True
    assert rule_matches(_rule(enabled=False), _ev()) is False


def test_rule_matches_filters():
    assert rule_matches(_rule(host_filter="web"), _ev(host="web01")) is True
    assert rule_matches(_rule(host_filter="db"), _ev(host="web01")) is False
    assert rule_matches(_rule(service_filter="Disk"), _ev(service="Memory")) is False


def test_tags_match_name_only_matches_any_value():
    assert tags_match({"prod": ""}, {"prod": "yes"}) is True
    assert tags_match({"prod": ""}, {"other": "x"}) is False


def test_tags_match_name_value_requires_exact_match():
    assert tags_match({"env": "prod"}, {"env": "prod"}) is True
    assert tags_match({"env": "prod"}, {"env": "staging"}) is False


def test_tags_match_requires_every_filter_key():
    assert tags_match({"env": "prod", "critical": ""}, {"env": "prod"}) is False
    assert tags_match({"env": "prod", "critical": ""}, {"env": "prod", "critical": "yes"}) is True


def test_tags_match_none_or_empty_filter_always_matches():
    assert tags_match(None, {}) is True
    assert tags_match({}, {"env": "prod"}) is True


def test_rule_matches_tag_filter():
    assert rule_matches(_rule(tag_filter={"env": "prod"}), _ev(tags={"env": "prod"})) is True
    assert rule_matches(_rule(tag_filter={"env": "prod"}), _ev(tags={"env": "staging"})) is False
    assert rule_matches(_rule(tag_filter={"env": "prod"}), _ev(tags={})) is False


def test_render_subject_and_body():
    subj, body = notification.render(_ev(state="CRIT"))
    assert "CRIT PROBLEM" in subj and "Memory on web01" in subj
    assert "State:   CRIT" in body
    subj2, _ = notification.render(_ev(state="OK", event="recovery"))
    assert "RECOVERED" in subj2


async def test_dispatch_sends_and_logs(db_session):
    settings = Settings(database_url="x", smtp_host="localhost")
    rule = _rule(channel="email")
    db_session.add(rule)
    await db_session.flush()

    sent = []
    ok_email = lambda s, to, subj, body: sent.append((to, subj))  # noqa: E731
    logs = await notification.dispatch(db_session, settings, _ev(), email_sender=ok_email)
    assert len(logs) == 1 and logs[0].status == "sent"
    assert sent and sent[0][0] == "ops@example.com"

    # A raising sender is logged as failed, never propagated.
    def boom(*a):
        raise RuntimeError("smtp down")

    logs2 = await notification.dispatch(db_session, settings, _ev(), email_sender=boom)
    assert logs2[0].status == "failed" and "smtp down" in logs2[0].error

    for r in (await db_session.scalars(select(Notification))).all():
        await db_session.delete(r)
    await db_session.delete(rule)
    await db_session.commit()


async def test_dispatch_disabled_globally(db_session):
    settings = Settings(database_url="x", notifications_enabled=False)
    logs = await notification.dispatch(db_session, settings, _ev(), email_sender=lambda *a: None)
    assert logs == []


async def test_collect_and_dispatch_suppression(db_session):
    """A hard problem notifies once; ack, downtime and flapping each
    suppress it."""
    settings = Settings(database_url="x", smtp_host="localhost")
    rule = _rule(channel="email")
    db_session.add(rule)
    agent = Agent(name=f"notif-{uuid.uuid4().hex[:8]}", token="t", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()

    now = datetime.now(timezone.utc)

    def make_svc(name, **kw):
        s = Service(agent_id=agent.id, name=name, metric="", state="CRIT", value=1.0, output="bad",
                    last_state_change=now, last_checked=now, state_type="hard", attempt=3, max_attempts=3)
        for k, v in kw.items():
            setattr(s, k, v)
        db_session.add(s)
        return s

    normal = make_svc("Memory")
    acked = make_svc("Disk /", acknowledged=True)
    flapping = make_svc("CPU", is_flapping=True)
    await db_session.flush()

    # A service under an active downtime.
    downed = make_svc("Uptime")
    await db_session.flush()
    db_session.add(Downtime(agent_id=agent.id, service_name="Uptime", starts_at=now - timedelta(hours=1),
                            ends_at=now + timedelta(hours=1), comment="maint"))
    await db_session.flush()

    for s in (normal, acked, flapping, downed):
        s._notify_event = "problem"
        s._notify_agent_name = agent.name

    sent = []
    n = await notification.collect_and_dispatch(
        db_session, settings, [normal, acked, flapping, downed], email_sender=lambda st, to, su, b: sent.append(su)
    )
    assert n == 1, "only the un-suppressed service dispatched"
    assert len(sent) == 1 and "Memory" in sent[0]

    for r in (await db_session.scalars(select(Notification))).all():
        await db_session.delete(r)
    for s in (normal, acked, flapping, downed):
        await db_session.delete(s)
    for d in (await db_session.scalars(select(Downtime).where(Downtime.agent_id == agent.id))).all():
        await db_session.delete(d)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(rule)
    await db_session.commit()


async def test_collect_and_dispatch_suppresses_dependent_service(db_session):
    """Block K8 (trigger dependencies): a symptom service whose CheckRule
    depends_on_service_name points at a root-cause service that is ALSO a
    confirmed hard problem doesn't notify; it does notify once the
    root-cause has recovered."""
    settings = Settings(database_url="x", smtp_host="localhost")
    dependent_rule = CheckRule(
        service_name="Backup job", metric="backup_ok", comparison="lt",
        warn_threshold=1.0, crit_threshold=1.0, scope_type="global",
        enabled=True, depends_on_service_name="Disk /",
    )
    db_session.add(dependent_rule)
    notify_rule = _rule(channel="email")  # matches any service — proves the fake sender actually fires
    db_session.add(notify_rule)
    agent = Agent(name=f"notif-{uuid.uuid4().hex[:8]}", token="t", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()

    now = datetime.now(timezone.utc)
    root_cause = Service(
        agent_id=agent.id, name="Disk /", metric="", state="CRIT", value=1.0, output="disk full",
        last_state_change=now, last_checked=now, state_type="hard", attempt=3, max_attempts=3,
    )
    db_session.add(root_cause)
    await db_session.flush()

    symptom = Service(
        agent_id=agent.id, name="Backup job", metric="", state="CRIT", value=1.0, output="backup failed",
        last_state_change=now, last_checked=now, state_type="hard", attempt=3, max_attempts=3,
        rule_id=dependent_rule.id,
    )
    db_session.add(symptom)
    await db_session.flush()
    symptom._notify_event = "problem"
    symptom._notify_agent_name = agent.name

    sent = []
    n = await notification.collect_and_dispatch(
        db_session, settings, [symptom], email_sender=lambda st, to, su, b: sent.append(su)
    )
    assert n == 0, "suppressed: root-cause (Disk /) is still an active hard problem"
    assert sent == []

    # Root cause recovers — the symptom's next confirmed change now notifies.
    root_cause.state = "OK"
    await db_session.flush()
    n2 = await notification.collect_and_dispatch(
        db_session, settings, [symptom], email_sender=lambda st, to, su, b: sent.append(su)
    )
    assert n2 == 1
    assert len(sent) == 1 and "Backup job" in sent[0]

    for r in (await db_session.scalars(select(Notification))).all():
        await db_session.delete(r)
    await db_session.delete(symptom)
    await db_session.delete(root_cause)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(dependent_rule)
    await db_session.delete(notify_rule)
    await db_session.commit()


async def test_dispatch_scope_is_additive(db_session):
    """Block N1: every rule whose scope covers (host, service) fires; scoped
    rules that don't cover it stay silent. host/service scope now actually
    applies at dispatch (previously the scope columns were ignored)."""
    settings = Settings(notifications_enabled=True)
    agent = Agent(name="web01", token=f"t-{uuid.uuid4().hex}", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()

    # Distinct targets so we can tell which rules fired from the log.
    rules = [
        _rule(name="g", scope_type="global", target="global@x"),
        _rule(name="h-hit", scope_type="host", scope_value="web01", target="host-hit@x"),
        _rule(name="h-miss", scope_type="host", scope_value="other", target="host-miss@x"),
        _rule(name="s-hit", scope_type="service", scope_value="web01", scope_service_name="Memory", target="svc-hit@x"),
        _rule(name="s-miss", scope_type="service", scope_value="web01", scope_service_name="CPU load", target="svc-miss@x"),
    ]
    for r in rules:
        db_session.add(r)
    await db_session.flush()

    sent: list[str] = []
    logs = await notification.dispatch(
        db_session, settings, _ev(host="web01", service="Memory"),
        email_sender=lambda _s, to, _sub, _b: sent.append(to),
    )
    fired = {n.target for n in logs}
    assert fired == {"global@x", "host-hit@x", "svc-hit@x"}
    assert "host-miss@x" not in fired and "svc-miss@x" not in fired

    await db_session.flush()  # persist the log rows dispatch only session.add-ed
    for n in logs:
        await db_session.delete(n)
    for r in rules:
        await db_session.delete(r)
    await db_session.delete(agent)
    await db_session.commit()


async def test_a_down_host_pages_once_not_once_per_service(db_session):
    """L3: a confirmed-down host reports ONE problem — "Host alive" — and silences the rest.

    This is what makes L1 usable. Once an aged-out reading correctly becomes UNKNOWN, a
    single dead host would otherwise fire one notification per service it carries; on
    vpp0221 that is 26 pages for one event. The other services keep their honest state,
    they just do not page while the cause is already paging.
    """
    from bossman.services.monitoring import HOST_ALIVE_SERVICE

    settings = Settings(database_url="x", smtp_host="localhost")
    rule = _rule(channel="email")
    db_session.add(rule)
    agent = Agent(name=f"down-{uuid.uuid4().hex[:8]}", token="t", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()

    now = datetime.now(timezone.utc)

    def make_svc(name, state="CRIT", output="bad"):
        s = Service(agent_id=agent.id, name=name, metric="", state=state, value=None, output=output,
                    last_state_change=now, last_checked=now, state_type="hard", attempt=3, max_attempts=3)
        db_session.add(s)
        return s

    host = make_svc(HOST_ALIVE_SERVICE, output="no answer from 10.0.0.9:9000")
    mem = make_svc("Memory", state="UNKNOWN", output="no data for 6 minutes")
    disk = make_svc("Disk /", state="UNKNOWN", output="no data for 6 minutes")
    await db_session.flush()

    for s in (host, mem, disk):
        s._notify_event = "problem"
        s._notify_agent_name = agent.name

    sent = []
    n = await notification.collect_and_dispatch(
        db_session, settings, [host, mem, disk], email_sender=lambda st, to, su, b: sent.append(su)
    )

    assert n == 1, "one event for one outage"
    assert HOST_ALIVE_SERVICE in sent[0], f"the cause must be what pages, got {sent[0]!r}"
    assert mem.state == "UNKNOWN", "suppressing the page must not rewrite the state"

    for r in (await db_session.scalars(select(Notification))).all():
        await db_session.delete(r)
    for s in (host, mem, disk):
        await db_session.delete(s)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(rule)
    await db_session.commit()


async def test_a_healthy_host_still_pages_for_its_services(db_session):
    """The counter-check: L3 must not silence services on a host that is fine."""
    settings = Settings(database_url="x", smtp_host="localhost")
    rule = _rule(channel="email")
    db_session.add(rule)
    agent = Agent(name=f"up-{uuid.uuid4().hex[:8]}", token="t", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()

    now = datetime.now(timezone.utc)
    mem = Service(agent_id=agent.id, name="Memory", metric="", state="CRIT", value=91.0, output="91% >= crit 90%",
                  last_state_change=now, last_checked=now, state_type="hard", attempt=3, max_attempts=3)
    db_session.add(mem)
    await db_session.flush()
    mem._notify_event = "problem"
    mem._notify_agent_name = agent.name

    sent = []
    n = await notification.collect_and_dispatch(
        db_session, settings, [mem], email_sender=lambda st, to, su, b: sent.append(su)
    )
    assert n == 1 and "Memory" in sent[0]

    for r in (await db_session.scalars(select(Notification))).all():
        await db_session.delete(r)
    await db_session.delete(mem)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(rule)
    await db_session.commit()


# ---------------------------------------------------------------------------
# L4 — time periods gate the send, and say so in the log


async def _period(db_session, name, ranges, excludes=None, exceptions=None):
    from bossman.db.models import TimePeriod

    tp = TimePeriod(
        name=f"{name}-{uuid.uuid4().hex[:6]}", alias=name, ranges=ranges,
        exceptions=exceptions or {}, excludes=excludes or [],
    )
    db_session.add(tp)
    await db_session.flush()
    return tp


async def test_a_rule_outside_its_window_does_not_send_but_is_logged(db_session):
    """Suppression must be visible: "why did nobody get paged" has to be answerable.

    A silently skipped rule makes a time period indistinguishable from a lost alert, so
    the log gets a `suppressed` row naming the window instead of nothing at all.
    """
    settings = Settings(database_url="x", smtp_host="localhost")
    # A window that is closed on every weekday — so "now" is always outside it.
    closed = await _period(db_session, "closed", {})
    rule = _rule(channel="email")
    rule.time_period_id = closed.id
    db_session.add(rule)
    agent = Agent(name=f"tp-{uuid.uuid4().hex[:8]}", token="t", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()

    sent = []
    logs = await notification.dispatch(
        db_session, settings, _ev(host=agent.name), email_sender=lambda st, to, su, b: sent.append(su)
    )

    assert sent == [], "nothing may go out outside the window"
    assert [l.status for l in logs] == ["suppressed"]
    assert "outside time period" in (logs[0].error or "")
    assert "closed" in (logs[0].error or ""), "the window must be named"

    for r in (await db_session.scalars(select(Notification))).all():
        await db_session.delete(r)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(rule)
    await db_session.delete(closed)
    await db_session.commit()


async def test_a_rule_inside_its_window_sends_normally(db_session):
    settings = Settings(database_url="x", smtp_host="localhost")
    always = await _period(
        db_session, "always",
        {d: [["00:00", "24:00"]] for d in
         ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")},
    )
    rule = _rule(channel="email")
    rule.time_period_id = always.id
    db_session.add(rule)
    agent = Agent(name=f"tp-{uuid.uuid4().hex[:8]}", token="t", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()

    sent = []
    logs = await notification.dispatch(
        db_session, settings, _ev(host=agent.name), email_sender=lambda st, to, su, b: sent.append(su)
    )
    assert len(sent) == 1
    assert [l.status for l in logs] == ["sent"]

    for r in (await db_session.scalars(select(Notification))).all():
        await db_session.delete(r)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(rule)
    await db_session.delete(always)
    await db_session.commit()


async def test_a_rule_without_a_window_is_unrestricted(db_session):
    """NULL means always — which is what every rule meant before L4 existed."""
    settings = Settings(database_url="x", smtp_host="localhost")
    rule = _rule(channel="email")
    assert rule.time_period_id is None
    db_session.add(rule)
    agent = Agent(name=f"tp-{uuid.uuid4().hex[:8]}", token="t", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()

    sent = []
    await notification.dispatch(
        db_session, settings, _ev(host=agent.name), email_sender=lambda st, to, su, b: sent.append(su)
    )
    assert len(sent) == 1

    for r in (await db_session.scalars(select(Notification))).all():
        await db_session.delete(r)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(rule)
    await db_session.commit()


async def test_an_unevaluable_window_does_not_silence_the_rule(db_session):
    """A page not sent is worse than a page sent at the wrong hour.

    A period whose `excludes` names something that no longer exists cannot be evaluated.
    Failing closed would turn a config error into silent alert loss, so it fails OPEN and
    logs a warning.
    """
    settings = Settings(database_url="x", smtp_host="localhost")
    broken = await _period(db_session, "broken", {"monday": [["00:00", "24:00"]]}, excludes=["ghost-period"])
    rule = _rule(channel="email")
    rule.time_period_id = broken.id
    db_session.add(rule)
    agent = Agent(name=f"tp-{uuid.uuid4().hex[:8]}", token="t", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()

    sent = []
    await notification.dispatch(
        db_session, settings, _ev(host=agent.name), email_sender=lambda st, to, su, b: sent.append(su)
    )
    assert len(sent) == 1, "a broken window must not swallow the alert"

    for r in (await db_session.scalars(select(Notification))).all():
        await db_session.delete(r)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(rule)
    await db_session.delete(broken)
    await db_session.commit()
