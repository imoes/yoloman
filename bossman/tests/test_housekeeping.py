"""Real, DB-backed tests for bossman.services.housekeeping (Block K1) —
see tests/conftest.py's db_session fixture (skips if no DB is reachable).

Scoped to notifications/plan_runs: metrics/connection_events/
service_state_history are TimescaleDB hypertables with their own native
add_retention_policy(...) jobs (see the module docstring) and are
deliberately NOT touched here.
"""

import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from bossman.config import get_settings
from bossman.db.models import Agent, Notification
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
    settings.notifications_retention_days = 90

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
    db_session.add_all([old_notif, fresh_notif])
    await db_session.commit()

    deleted = await run_housekeeping(db_session, settings, now)

    assert deleted["notifications"] >= 1

    remaining_notifs = (
        await db_session.scalars(select(Notification).where(Notification.agent_name == agent.name))
    ).all()
    assert len(remaining_notifs) == 1
    assert remaining_notifs[0].event == "recovery"

    await db_session.delete(fresh_notif)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def test_run_housekeeping_covers_exactly_its_own_tables(db_session):
    """Regression guard: run_housekeeping must NOT touch metrics /
    connection_events / service_state_history — those are TimescaleDB-native (see the module
    docstring), and re-adding them here would silently resurrect the original K1 bug (a
    Settings change with no real effect).

    The set is asserted exactly, not as a subset, so BOTH directions are caught: a
    hypertable sneaking back in, and one of these sweeps quietly disappearing. It grew from
    two entries to four as real work was added — per-process series pruning and the orphaned
    metric_series sweep (the latter cleans up after an agent delete, whose own DELETE is
    time-bounded so it cannot decompress the whole hypertable). Both are plain PostgreSQL
    tables, which is exactly why they belong here.
    """
    settings = get_settings()
    now = datetime.now(timezone.utc)

    deleted = await run_housekeeping(db_session, settings, now)

    assert set(deleted.keys()) == {
        "notifications",
        "plan_runs",
        "process_series_stale",
        "metric_series_orphans",
    }
