"""Trending / capacity forecasting (gap #3): project a metric forward with a
least-squares trend line and answer "how long until it crosses a threshold" —
e.g. "disk full in N days". Pure on-demand (reads the metric history via
query_series); no background loop, no new tables, no numpy — a closed-form OLS.

A metric like disk_used_pct fans out per filesystem via labels['mount'], so a
forecast is computed per label group.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import Agent
from bossman.services.metrics_query import SeriesPoint, query_series

_DAY = 86400.0


def _ols(xs: list[float], ys: list[float]) -> tuple[float, float]:
    """Ordinary least squares → (slope, intercept) for y = slope*x + intercept.
    Returns (0, mean) when x has no spread."""
    n = len(xs)
    if n < 2:
        return 0.0, (ys[0] if ys else 0.0)
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return 0.0, my
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    slope = sxy / sxx
    return slope, my - slope * mx


@dataclass
class Forecast:
    label: str                      # the label group (e.g. mount), or "" if none
    current: float                  # last observed value
    slope_per_day: float            # trend (units/day)
    days_to_threshold: float | None  # None = not trending toward it
    eta: datetime | None            # projected crossing time
    threshold: float
    points_used: int
    tier: str


def _forecast_points(points: list[SeriesPoint], threshold: float, now: datetime) -> Forecast | None:
    if len(points) < 2:
        return None
    t0 = points[0].time
    xs = [(p.time - t0).total_seconds() / _DAY for p in points]
    ys = [float(p.value) for p in points]
    slope, intercept = _ols(xs, ys)  # per day
    current = ys[-1]
    label = str(points[-1].labels.get("mount") or points[-1].labels.get("iface") or "")

    days_to: float | None = None
    eta: datetime | None = None
    # Beyond this horizon a trend is meaningless noise — treat as "not trending".
    _MAX_HORIZON_DAYS = 3650.0  # 10 years
    if current >= threshold:
        days_to, eta = 0.0, now
    elif slope > 1e-6:
        # project from the LAST observed point along the trend
        d = (threshold - current) / slope
        if 0 <= d <= _MAX_HORIZON_DAYS:
            days_to, eta = d, now + timedelta(days=d)
    return Forecast(
        label=label, current=round(current, 2), slope_per_day=round(slope, 4),
        days_to_threshold=round(days_to, 1) if days_to is not None else None,
        eta=eta, threshold=threshold, points_used=len(points), tier="",
    )


async def forecast_metric(
    session: AsyncSession, settings: Settings, agent_id, metric: str, threshold: float,
    lookback_days: int = 30, now: datetime | None = None,
) -> list[Forecast]:
    """Forecast one agent+metric, one result per label group (e.g. per mount)."""
    now = now or datetime.now(timezone.utc)
    since = now - timedelta(days=lookback_days)
    tier, points = await query_series(session, settings, agent_id, metric, since, now)
    if not points:
        return []
    groups: dict[str, list[SeriesPoint]] = {}
    for p in points:
        key = str(p.labels.get("mount") or p.labels.get("iface") or "")
        groups.setdefault(key, []).append(p)
    out: list[Forecast] = []
    for pts in groups.values():
        f = _forecast_points(pts, threshold, now)
        if f is not None:
            f.tier = tier
            out.append(f)
    return out


def status_for(days_to: float | None, slope_per_day: float, warn_days: int, crit_days: int) -> str:
    """crit/warn/ok from the projected days-to-threshold. A flat/shrinking series
    (no ETA) is 'ok'."""
    if days_to is None:
        return "ok"
    if days_to <= crit_days:
        return "critical"
    if days_to <= warn_days:
        return "warning"
    return "ok"


@dataclass
class CapacityRow:
    agent_id: str
    host: str
    label: str
    current: float
    slope_per_day: float
    days_to_threshold: float | None
    eta: datetime | None
    threshold: float
    status: str


async def capacity_forecast(
    session: AsyncSession, settings: Settings, *, metric: str = "disk_used_pct", threshold: float = 90.0,
    lookback_days: int = 30, warn_days: int = 30, crit_days: int = 7, now: datetime | None = None,
) -> list[CapacityRow]:
    """Fleet-wide capacity board: for every host, project `metric` (per mount)
    and report time-to-threshold, sorted soonest-first."""
    now = now or datetime.now(timezone.utc)
    agents = (await session.scalars(select(Agent))).all()
    rows: list[CapacityRow] = []
    for agent in agents:
        for f in await forecast_metric(session, settings, agent.id, metric, threshold, lookback_days, now):
            rows.append(CapacityRow(
                agent_id=str(agent.id), host=agent.name, label=f.label, current=f.current,
                slope_per_day=f.slope_per_day, days_to_threshold=f.days_to_threshold, eta=f.eta,
                threshold=threshold, status=status_for(f.days_to_threshold, f.slope_per_day, warn_days, crit_days),
            ))
    # soonest ETA first; None (not trending) sorts last.
    rows.sort(key=lambda r: r.days_to_threshold if r.days_to_threshold is not None else float("inf"))
    return rows
