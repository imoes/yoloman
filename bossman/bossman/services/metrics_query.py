"""Tiered metric-series reads (Zabbix gap-analysis Block K1b — "History +
Trends"): a requested time range picks raw `metrics`, the `metrics_hourly`
continuous aggregate, or the `metrics_daily` one, so a graph reaching
further back than `metrics`'s 14-day TimescaleDB retention still returns
real (downsampled) data instead of nothing. `metrics_hourly`/`metrics_daily`
are materialized views, not SQLAlchemy models — read via raw SQL, since
that's the only way to query a continuous aggregate.

Framework-free (no FastAPI import), like services/poller.py, so it's
reachable from the REST API and tests without duplicating logic.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings


@dataclass
class SeriesPoint:
    """One point of a queried series. min_value/max_value are None for the
    raw tier (a single true sample has no range) and populated for the
    hourly/daily tiers (the consolidated bucket's spread)."""

    time: datetime
    value: float
    labels: dict
    min_value: float | None = None
    max_value: float | None = None


def pick_tier(settings: Settings, since: datetime | None, now: datetime) -> str:
    """Chooses "raw" | "5min" | "hourly" | "daily" based on how far back
    `since` reaches, using the informational retention mirrors in Settings as
    the tier boundaries (see config.py's Block K1b comment). Mirrors Checkmk's
    RRA cascade: full-res for a couple of days, then progressively coarser."""
    if since is None:
        return "raw"
    age_days = (now - since).total_seconds() / 86400
    if age_days <= settings.metrics_retention_days:
        return "raw"
    if age_days <= settings.metrics_5min_retention_days:
        return "5min"
    if age_days <= settings.metrics_hourly_retention_days:
        return "hourly"
    return "daily"


def _parse_labels(raw: object) -> dict:
    if isinstance(raw, str):
        return json.loads(raw)
    return raw or {}


async def query_series(
    session: AsyncSession,
    settings: Settings,
    agent_id,
    metric: str,
    since: datetime | None,
    now: datetime | None = None,
) -> tuple[str, list[SeriesPoint]]:
    """Returns (tier, points) for one agent+metric series, automatically
    selecting raw/hourly/daily based on `since`'s age. `now` is injectable
    for tests; defaults to the real current time."""
    now = now or datetime.now(timezone.utc)
    tier = pick_tier(settings, since, now)

    if tier == "raw":
        stmt = text(
            "SELECT time, value, labels FROM metrics "
            "WHERE agent_id = :agent_id AND metric = :metric "
            + ("AND time >= :since " if since is not None else "")
            + "ORDER BY time"
        )
        params = {"agent_id": str(agent_id), "metric": metric}
        if since is not None:
            params["since"] = since
        rows = (await session.execute(stmt, params)).all()
        return "raw", [SeriesPoint(time=r.time, value=r.value, labels=_parse_labels(r.labels)) for r in rows]

    view = {"5min": "metrics_5min", "hourly": "metrics_hourly", "daily": "metrics_daily"}[tier]
    stmt = text(
        f"SELECT bucket AS time, avg_value, min_value, max_value, labels FROM {view} "
        "WHERE agent_id = :agent_id AND metric = :metric AND bucket >= :since "
        "ORDER BY bucket"
    )
    rows = (await session.execute(stmt, {"agent_id": str(agent_id), "metric": metric, "since": since})).all()
    return tier, [
        SeriesPoint(
            time=r.time,
            value=r.avg_value,
            min_value=r.min_value,
            max_value=r.max_value,
            labels=_parse_labels(r.labels),
        )
        for r in rows
    ]
