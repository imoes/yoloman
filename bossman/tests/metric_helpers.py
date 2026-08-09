"""Writing metrics in tests: `metrics` is a VIEW, so it takes no INSERT.

Since the series normalisation, `metrics` is a view over
(metric_series JOIN metrics_raw) and every `db_session.add(Metric(...))` fails with
"cannot insert into view metrics". That broke every DB-backed test that seeded a metric —
silently, in the sense that the suite had so much other noise the cause was never chased.

One helper rather than the same six lines in each test file, so the reason is written down
once and the next test that needs a data point does not rediscover it.

Two mounts (or any two label sets) may share one timestamp on purpose: that is what the real
agent does, distinct labels are distinct series, and the Metric ORM key is (series_id, time) —
see models.Metric and migration e7b2f4a19c33. Nothing needs staggering by a microsecond.
"""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import delete, select

from bossman.db.models import MetricRaw, MetricSeries


async def write_metric(session, agent_id, metric, value, *, when=None, labels=None):
    """Insert one data point through metric_series + metrics_raw. Returns the series."""
    labels = labels or {}
    series = await session.scalar(
        select(MetricSeries).where(
            MetricSeries.agent_id == agent_id,
            MetricSeries.metric == metric,
            MetricSeries.labels == labels,
        )
    )
    if series is None:
        series = MetricSeries(agent_id=agent_id, metric=metric, labels=labels)
        session.add(series)
        await session.flush()
    session.add(MetricRaw(series_id=series.series_id, time=when or datetime.now(timezone.utc), value=value))
    await session.flush()
    return series


async def purge_metrics(session, agent_id):
    """Remove an agent's points and their series — the view takes no DELETE either."""
    ids = list((await session.scalars(select(MetricSeries.series_id).where(MetricSeries.agent_id == agent_id))).all())
    if ids:
        await session.execute(delete(MetricRaw).where(MetricRaw.series_id.in_(ids)))
        await session.execute(delete(MetricSeries).where(MetricSeries.series_id.in_(ids)))
    await session.flush()
