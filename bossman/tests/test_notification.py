"""Tests for services/notification.py (Block H8): rule matching, rendering,
dispatch with injected fake senders (no real SMTP/HTTP), and the
ack/downtime/flapping suppression in collect_and_dispatch."""

import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from bossman.config import Settings
from bossman.db.models import Agent, Downtime, Notification, NotificationRule, Service
from bossman.services import notification
from bossman.services.notification import NotifyEvent, rule_matches


def _rule(**kw):
    fields = dict(
        name="r", enabled=True, on_problem=True, on_recovery=True, min_state="WARN",
        host_filter=None, service_filter=None, channel="email", target="ops@example.com",
    )
    fields.update(kw)
    return NotificationRule(**fields)


def _ev(state="CRIT", event="problem", host="web01", service="Memory"):
    return NotifyEvent(agent_name=host, service_name=service, state=state, event=event, output="x")


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
