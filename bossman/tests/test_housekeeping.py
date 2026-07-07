"""Real, DB-backed tests for bossman.services.housekeeping (Block K1) —
see tests/conftest.py's db_session fixture (skips if no DB is reachable).
"""

import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from bossman.config import get_settings
from bossman.db.models import Agent, ConnectionEvent, Metric, Notification, ServiceStateHistory
from bossman.services.housekeeping import run_housekeeping


async def _make_agent(db_session) -> Agent:
    agent = Agent(name=f"hk-{uuid.uuid4().hex[:8]}", token="tok", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def test_run_housekeeping_deletes_only_rows_past_retention(db_session):
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    settings = get_settings()
    settings.metrics_retention_days = 14
    settings.notifications_retention_days = 90

    old_metric = Metric(time=now - timedelta(days=20), agent_id=agent.id, metric="cpu_pct", value=1.0, labels={})
    fresh_metric = Metric(time=now - timedelta(days=1), agent_id=agent.id, metric="cpu_pct", value=2.0, labels={})
    old_notif = Notification(
        agent_name=agent.name,
        service_name="CPU load",
        event="problem",
        state="CRIT",
        channel="webhook",
        target="http://x",
        status="sent",
        created_at=now - timedelta(days=200),
    )
    fresh_notif = Notification(
        agent_name=agent.name,
        service_name="CPU load",
        event="recovery",
        state="OK",
        channel="webhook",
        target="http://x",
        status="sent",
        created_at=now - timedelta(days=1),
    )
    db_session.add_all([old_metric, fresh_metric, old_notif, fresh_notif])
    await db_session.commit()

    deleted = await run_housekeeping(db_session, settings, now)

    assert deleted["metrics"] >= 1
    assert deleted["notifications"] >= 1

    remaining_metrics = (await db_session.scalars(select(Metric).where(Metric.agent_id == agent.id))).all()
    assert [m.value for m in remaining_metrics] == [2.0]

    remaining_notifs = (
        await db_session.scalars(select(Notification).where(Notification.agent_name == agent.name))
    ).all()
    assert len(remaining_notifs) == 1
    assert remaining_notifs[0].event == "recovery"

    await db_session.delete(fresh_metric)
    await db_session.delete(fresh_notif)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def test_run_housekeeping_covers_all_configured_tables(db_session):
    """Every table named in Settings has a corresponding delete — a
    regression guard against silently dropping a table from the sweep
    (e.g. if a new retention field is added to config.py but never wired
    into run_housekeeping's plan list)."""
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    settings = get_settings()

    old_conn = ConnectionEvent(
        time=now - timedelta(days=40),
        src_agent_id=agent.id,
        comm="curl",
        dst_addr="10.0.0.1",
        dst_port=443,
        new_state="ESTABLISHED",
    )
    old_hist = ServiceStateHistory(
        time=now - timedelta(days=40), agent_id=agent.id, service_name="CPU load", state="OK", value=1.0
    )
    db_session.add_all([old_conn, old_hist])
    await db_session.commit()

    deleted = await run_housekeeping(db_session, settings, now)

    assert set(deleted.keys()) == {
        "metrics",
        "connection_events",
        "service_state_history",
        "notifications",
        "plan_runs",
    }
    assert deleted["connection_events"] >= 1
    assert deleted["service_state_history"] >= 1

    await db_session.delete(agent)
    await db_session.commit()
