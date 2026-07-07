"""Runtime operational control plane (Zabbix gap-analysis Block K2):
Zabbix's server exposes live diagnostics (`diaginfo`), log-level control,
and an on-demand housekeeper trigger, all without a restart. Bossman had
no equivalent — the only way to see "is the poller stuck?" or "how much
retained data is there?" was to query Postgres directly, and the only way
to change logging verbosity was to redeploy. This gives an authenticated
operator three things: a diagnostics snapshot, a live log-level switch,
and an on-demand housekeeping run (K1's retention, triggered now instead
of waiting for the next hourly tick).
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services.housekeeping import HousekeepingStats, run_housekeeping
from bossman.services.monitoring import fleet_summary
from bossman.services.poller import PollerStats

router = APIRouter()

_VALID_LEVELS = ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL")


def get_poller_stats(request: Request) -> PollerStats:
    return request.app.state.poller_stats


def get_housekeeping_stats(request: Request) -> HousekeepingStats:
    return request.app.state.housekeeping_stats


class PollerDiagnosticsOut(BaseModel):
    last_run_at: datetime | None
    last_run_duration_ms: float | None
    agents_polled: int
    agents_with_errors: int


class HousekeepingDiagnosticsOut(BaseModel):
    last_run_at: datetime | None
    last_run_duration_ms: float | None
    deleted: dict[str, int]
    last_error: str | None


class DiagnosticsOut(BaseModel):
    log_level: str
    open_problems: int
    db_pool_size: int
    db_pool_checked_out: int
    poller: PollerDiagnosticsOut
    housekeeping: HousekeepingDiagnosticsOut


@router.get("/api/v1/admin/diagnostics", response_model=DiagnosticsOut)
async def get_diagnostics(
    request: Request,
    session: AsyncSession = Depends(get_session),
    poller_stats: PollerStats = Depends(get_poller_stats),
    housekeeping_stats: HousekeepingStats = Depends(get_housekeeping_stats),
    _identity=Depends(get_current_identity),
) -> DiagnosticsOut:
    summary = await fleet_summary(session)
    pool = request.app.state.engine.pool
    return DiagnosticsOut(
        log_level=logging.getLevelName(logging.getLogger().getEffectiveLevel()),
        open_problems=summary.open_problems,
        db_pool_size=pool.size(),
        db_pool_checked_out=pool.checkedout(),
        poller=PollerDiagnosticsOut(
            last_run_at=poller_stats.last_run_at,
            last_run_duration_ms=poller_stats.last_run_duration_ms,
            agents_polled=poller_stats.agents_polled,
            agents_with_errors=poller_stats.agents_with_errors,
        ),
        housekeeping=HousekeepingDiagnosticsOut(
            last_run_at=housekeeping_stats.last_run_at,
            last_run_duration_ms=housekeeping_stats.last_run_duration_ms,
            deleted=housekeeping_stats.deleted,
            last_error=housekeeping_stats.last_error,
        ),
    )


class LogLevelRequest(BaseModel):
    level: str


class LogLevelOut(BaseModel):
    level: str


@router.post("/api/v1/admin/log-level", response_model=LogLevelOut)
async def set_log_level(
    body: LogLevelRequest,
    _identity=Depends(get_current_identity),
) -> LogLevelOut:
    level = body.level.upper()
    if level not in _VALID_LEVELS:
        raise HTTPException(status_code=422, detail=f"level must be one of {_VALID_LEVELS}")
    logging.getLogger().setLevel(level)
    return LogLevelOut(level=level)


class HousekeepingRunOut(BaseModel):
    deleted: dict[str, int]


@router.post("/api/v1/admin/housekeeping/run", response_model=HousekeepingRunOut)
async def run_housekeeping_now(
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    housekeeping_stats: HousekeepingStats = Depends(get_housekeeping_stats),
    _identity=Depends(get_current_identity),
) -> HousekeepingRunOut:
    now = datetime.now(timezone.utc)
    deleted = await run_housekeeping(session, settings, now)
    housekeeping_stats.last_run_at = now
    housekeeping_stats.deleted = deleted
    housekeeping_stats.last_error = None
    return HousekeepingRunOut(deleted=deleted)
