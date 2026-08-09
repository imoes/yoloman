"""Forecast / capacity-planning API (gap #3): project metrics to a threshold
("disk full in N days"). On-demand — no stored state.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services import forecast as fc

router = APIRouter()


class CapacityRowOut(BaseModel):
    agent_id: str
    host: str
    label: str
    current: float
    slope_per_day: float
    days_to_threshold: float | None
    eta: datetime | None
    threshold: float
    status: str


class ForecastOut(BaseModel):
    label: str
    current: float
    slope_per_day: float
    days_to_threshold: float | None
    eta: datetime | None
    threshold: float
    points_used: int
    tier: str


@router.get("/api/v1/forecast/capacity", response_model=list[CapacityRowOut])
async def capacity(
    metric: str = Query("disk_used_pct"),
    threshold: float = Query(90.0),
    lookback_days: int = Query(30, ge=2, le=365),
    warn_days: int = Query(30, ge=1),
    crit_days: int = Query(7, ge=1),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _i: Identity = Depends(get_current_identity),
):
    rows = await fc.capacity_forecast(
        session, settings, metric=metric, threshold=threshold,
        lookback_days=lookback_days, warn_days=warn_days, crit_days=crit_days,
    )
    return [CapacityRowOut(**r.__dict__) for r in rows]


@router.get("/api/v1/agents/{agent_id}/forecast", response_model=list[ForecastOut])
async def agent_forecast(
    agent_id: UUID,
    metric: str = Query("disk_used_pct"),
    threshold: float = Query(90.0),
    lookback_days: int = Query(30, ge=2, le=365),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _i: Identity = Depends(get_current_identity),
):
    fs = await fc.forecast_metric(session, settings, agent_id, metric, threshold, lookback_days)
    return [
        ForecastOut(
            label=f.label, current=f.current, slope_per_day=f.slope_per_day,
            days_to_threshold=f.days_to_threshold, eta=f.eta, threshold=f.threshold,
            points_used=f.points_used, tier=f.tier,
        )
        for f in fs
    ]
