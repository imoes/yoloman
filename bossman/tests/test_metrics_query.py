"""Real, DB-backed tests for bossman.services.metrics_query (Block K1b —
"History + Trends") against the actual TimescaleDB continuous aggregates
(metrics_hourly/metrics_daily), not mocks. `CALL refresh_continuous_
aggregate(..., NULL, NULL)` forces synchronous materialization so a test
doesn't have to wait for the real hourly/daily background job.

See tests/conftest.py's db_session fixture (skips if no DB is reachable).
"""

import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, text
from sqlalchemy.ext.asyncio import create_async_engine

from bossman.config import get_settings
from tests.metric_helpers import purge_metrics, write_metric
from bossman.db.models import Agent, Metric
from bossman.services.metrics_query import pick_tier, query_series


async def _make_agent(db_session) -> Agent:
    agent = Agent(name=f"mq-{uuid.uuid4().hex[:8]}", token="tok", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _refresh_continuous_aggregate(cagg: str) -> None:
    """`CALL refresh_continuous_aggregate(...)` cannot run inside a transaction block, but
    db_session keeps one open for the whole test (rolled back at teardown) — so this uses its
    own short-lived, autocommit connection instead of db_session.

    Takes the CONTINUOUS AGGREGATE's name, not the tier view's. Since the series
    normalisation, `metrics_hourly` is a plain view over `cagg_metrics_hourly` (so that
    existing reads keep their (agent_id, metric, labels) shape), and refreshing the view fails
    with "relation metrics_hourly is not a continuous aggregate".
    """
    settings = get_settings()
    engine = create_async_engine(settings.database_url)
    try:
        async with engine.connect() as conn:
            await conn.execution_options(isolation_level="AUTOCOMMIT")
            await conn.execute(text(f"CALL refresh_continuous_aggregate('{cagg}', NULL, NULL)"))
    finally:
        await engine.dispose()


def test_pick_tier_boundaries():
    """Walks the full cascade raw → 5min → hourly → daily, one step past each edge.

    The 5min tier was inserted between raw and hourly later; this test still asserted the
    old two-tier ladder ("just past raw retention ⇒ hourly") and so failed against correct
    code. Each boundary is checked on both sides, because the comparisons are `<=` and an
    off-by-one there silently serves a coarser resolution than the caller asked for.
    """
    settings = get_settings()
    now = datetime(2026, 1, 30, tzinfo=timezone.utc)
    assert pick_tier(settings, None, now) == "raw"
    assert pick_tier(settings, now - timedelta(days=1), now) == "raw"
    assert pick_tier(settings, now - timedelta(days=settings.metrics_retention_days), now) == "raw"
    assert pick_tier(settings, now - timedelta(days=settings.metrics_retention_days + 1), now) == "5min"
    assert pick_tier(settings, now - timedelta(days=settings.metrics_5min_retention_days), now) == "5min"
    assert pick_tier(settings, now - timedelta(days=settings.metrics_5min_retention_days + 1), now) == "hourly"
    assert pick_tier(settings, now - timedelta(days=settings.metrics_hourly_retention_days), now) == "hourly"
    assert pick_tier(settings, now - timedelta(days=settings.metrics_hourly_retention_days + 1), now) == "daily"


async def test_query_series_raw_tier(db_session):
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    # metrics is a VIEW — see tests/metric_helpers.
    await write_metric(db_session, agent.id, "cpu_pct", 42.0, when=now - timedelta(hours=1))
    await db_session.commit()

    settings = get_settings()
    tier, points = await query_series(db_session, settings, agent.id, "cpu_pct", now - timedelta(days=1), now=now)

    assert tier == "raw"
    assert len(points) == 1
    assert points[0].value == 42.0
    assert points[0].min_value is None

    await purge_metrics(db_session, agent.id)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def test_query_series_hourly_tier_reads_real_continuous_aggregate(db_session):
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    # Old enough that raw metrics would already be past TimescaleDB's own
    # 14-day retention in a real deployment — the whole point of this tier.
    # Truncated to the hour so both points land in the same time_bucket('1
    # hour', ...) regardless of what minute "now" happens to be.
    old_time = (now - timedelta(days=20)).replace(minute=0, second=0, microsecond=0)
    await write_metric(db_session, agent.id, "cpu_pct", 10.0, when=old_time)
    await write_metric(db_session, agent.id, "cpu_pct", 30.0, when=old_time + timedelta(minutes=10))
    await db_session.commit()

    # Force synchronous materialization instead of waiting for the real
    # hourly background job.
    await _refresh_continuous_aggregate("cagg_metrics_hourly")

    settings = get_settings()
    tier, points = await query_series(db_session, settings, agent.id, "cpu_pct", now - timedelta(days=30), now=now)

    assert tier == "hourly"
    assert len(points) >= 1
    bucket = points[0]
    assert bucket.value == 20.0  # avg(10, 30)
    assert bucket.min_value == 10.0
    assert bucket.max_value == 30.0

    await purge_metrics(db_session, agent.id)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def test_query_series_daily_tier_reads_real_continuous_aggregate(db_session):
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    # Truncated to midnight (UTC) so both points land in the same
    # time_bucket('1 day', ...) regardless of what hour "now" happens to be.
    old_time = (now - timedelta(days=120)).replace(hour=0, minute=0, second=0, microsecond=0)
    await write_metric(db_session, agent.id, "mem_pct", 50.0, when=old_time)
    await write_metric(db_session, agent.id, "mem_pct", 70.0, when=old_time + timedelta(hours=6))
    await db_session.commit()

    # The DAILY aggregate is hierarchical: it is defined over the HOURLY aggregate's
    # materialisation hypertable, not over metrics_raw (verified:
    # timescaledb_information.continuous_aggregates shows cagg_metrics_daily's
    # hypertable_name = cagg_metrics_hourly's materialization hypertable). So refreshing only
    # daily materialises nothing — the source it reads has not been filled yet. Reproduced
    # outside the test: raw points present, daily refresh alone gives 0 buckets; hourly first,
    # then daily, gives 1.
    #
    # Operationally this also means the daily tier can hold nothing older than the hourly
    # tier's 90-day retention, because after that the source rows are gone. Fine going forward
    # (data flows raw -> hourly -> daily while everything is still there), but backfill of an
    # old period is impossible by construction.
    await _refresh_continuous_aggregate("cagg_metrics_hourly")
    await _refresh_continuous_aggregate("cagg_metrics_daily")

    settings = get_settings()
    tier, points = await query_series(db_session, settings, agent.id, "mem_pct", now - timedelta(days=200), now=now)

    assert tier == "daily"
    assert len(points) >= 1
    bucket = points[0]
    assert bucket.value == 60.0  # avg(50, 70)
    assert bucket.min_value == 50.0
    assert bucket.max_value == 70.0

    await purge_metrics(db_session, agent.id)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()
