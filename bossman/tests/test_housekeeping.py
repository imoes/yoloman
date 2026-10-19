"""Real, DB-backed tests for bossman.services.housekeeping (Block K1) —
see tests/conftest.py's db_session fixture (skips if no DB is reachable).

Scoped to notifications/plan_runs: metrics/connection_events/
service_state_history are TimescaleDB hypertables with their own native
add_retention_policy(...) jobs (see the module docstring) and are
deliberately NOT touched here.
"""

import uuid
from tests.naming import owned_name
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from bossman.config import get_settings
from bossman.db.models import Agent, Notification
from bossman.services.housekeeping import run_housekeeping



#: What run_housekeeping sweeps. THE ONE LIST — tests/test_admin_api.py asserts against these too, and it
#: held a second copy that was three sweeps out of date, so the same exact-set assertion was red there while
#: it was green here. Adding a sweep means adding it here, once.
ALWAYS_SWEEPS = {"notifications", "plan_runs", "host_edges", "process_series_stale", "metric_series_orphans"}
#: These appear only when the operator has set a run-retention window (0 = keep forever), so an exact-set
#: assertion has to allow their absence rather than demand it.
OPTIONAL_SWEEPS = {"runbook_runs", "audit_log"}

async def _make_agent(db_session) -> Agent:
    agent = Agent(name=owned_name("hk"), token="tok", mode="standalone", enrollment_state="enrolled")
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

    assert set(deleted.keys()) - OPTIONAL_SWEEPS == ALWAYS_SWEEPS
    assert set(deleted.keys()) <= ALWAYS_SWEEPS | OPTIONAL_SWEEPS


async def test_process_prune_skips_a_series_the_poller_is_writing(db_session):
    """The prune's NOT EXISTS guard reads what was committed when its statement began; a point the poller inserts
    while it runs was only caught by the FK check, and the prune aborted on metrics_raw_series_id_fkey (measured
    twice in 40 minutes). A series with an in-flight insert holds a KEY SHARE lock; the prune now skips such rows
    (FOR UPDATE SKIP LOCKED) instead of waiting into the FK violation. The poller's point survives."""
    import asyncio

    from sqlalchemy import text
    from sqlalchemy.ext.asyncio import AsyncSession

    from bossman.services.housekeeping import prune_process_series

    agent = await _make_agent(db_session)
    sid = (await db_session.execute(text(
        "INSERT INTO metric_series (agent_id, metric, labels) VALUES (:a, 'process_cpu_percent', "
        "CAST(:l AS jsonb)) RETURNING series_id"), {"a": agent.id, "l": '{"pid":"4242","comm":"hk-test"}'})).scalar_one()
    await db_session.commit()
    engine = db_session.bind
    now = datetime.now(timezone.utc)
    async with AsyncSession(engine) as poller, AsyncSession(engine) as hk:
        # A point ten minutes old (before the stale cutoff, after the compression floor), uncommitted: it holds a
        # KEY SHARE lock on the series row. The prune runs at the REAL time — never a shifted clock on the one
        # shared database (a shifted `now` makes every live process series look stale).
        await poller.execute(text("INSERT INTO metrics_raw (time, series_id, value) VALUES (:t, :s, 1.0)"),
                             {"t": now - timedelta(minutes=10), "s": sid})
        await asyncio.wait_for(prune_process_series(hk, get_settings(), now), timeout=60)
        await poller.commit()                                 # the point is not lost
    left = (await db_session.execute(text("SELECT count(*) FROM metrics_raw WHERE series_id = :s"), {"s": sid})).scalar()
    assert left == 1
    await db_session.execute(text("DELETE FROM metrics_raw WHERE series_id = :s"), {"s": sid})
    await db_session.execute(text("DELETE FROM metric_series WHERE series_id = :s"), {"s": sid})
    await db_session.delete(agent)
    await db_session.commit()


async def test_orphan_sweep_skips_a_series_the_poller_is_writing(db_session):
    """A brand-new series has no committed point while the poller's first insert is in flight, so it looks orphaned;
    the sweep died on metrics_raw_series_id_fkey right after a restart (measured 2026-10-15). It now skips rows with
    a KEY SHARE lock (FOR UPDATE SKIP LOCKED) — without that it would wait on the poller here and time out."""
    import asyncio

    from sqlalchemy import text
    from sqlalchemy.ext.asyncio import AsyncSession

    from bossman.services.housekeeping import sweep_orphan_series

    agent = await _make_agent(db_session)
    sid = (await db_session.execute(text(
        "INSERT INTO metric_series (agent_id, metric, labels) VALUES (:a, 'hk_orphan_test', "
        "CAST(:l AS jsonb)) RETURNING series_id"), {"a": agent.id, "l": '{"case":"in-flight"}'})).scalar_one()
    await db_session.commit()
    engine = db_session.bind
    async with AsyncSession(engine) as poller, AsyncSession(engine) as hk:
        await poller.execute(text("INSERT INTO metrics_raw (time, series_id, value) VALUES (:t, :s, 1.0)"),
                             {"t": datetime.now(timezone.utc), "s": sid})
        await asyncio.wait_for(sweep_orphan_series(hk), timeout=60)
        await poller.commit()                                 # the first point is not lost
    left = (await db_session.execute(text("SELECT count(*) FROM metrics_raw WHERE series_id = :s"), {"s": sid})).scalar()
    assert left == 1
    await db_session.execute(text("DELETE FROM metrics_raw WHERE series_id = :s"), {"s": sid})
    await db_session.execute(text("DELETE FROM metric_series WHERE series_id = :s"), {"s": sid})
    await db_session.delete(agent)
    await db_session.commit()
