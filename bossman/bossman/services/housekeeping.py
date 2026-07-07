"""Configurable, on-demand data retention (Zabbix gap-analysis Block K1):
Zabbix's housekeeper is a dedicated, configurable, runtime-triggerable
server process (`housekeeper_execute`) — yolo-man's previous equivalent
was three retention windows hardcoded straight into Alembic migrations
(14/30/30 days), with no admin visibility or on-demand trigger, and two
tables (notifications, plan_runs) with no retention at all. This service
makes retention a Settings value per data type and exposes both a timer
(housekeeping_loop, mirroring poller_loop's shape) and an on-demand run
(run_housekeeping) for `POST /api/v1/admin/housekeeping/run`.

Framework-free (no FastAPI import), like services/poller.py, so it's
reachable from the app's background task, the admin route, and tests
without duplicating logic.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import ConnectionEvent, Metric, Notification, PlanRun, ServiceStateHistory

logger = logging.getLogger(__name__)


@dataclass
class HousekeepingStats:
    """Last-run outcome, surfaced by GET /api/v1/admin/diagnostics (Block
    K2) — mirrors Zabbix's housekeeper diagnostics."""

    last_run_at: datetime | None = None
    last_run_duration_ms: float | None = None
    deleted: dict[str, int] = field(default_factory=dict)
    last_error: str | None = None


async def run_housekeeping(session: AsyncSession, settings: Settings, now: datetime) -> dict[str, int]:
    """Deletes rows older than each table's configured retention. Returns
    a dict of table name -> rows deleted, for logging/diagnostics. One
    DELETE per table, each committed independently so a failure on one
    table doesn't roll back cleanup already done on the others."""
    plans = [
        ("metrics", Metric, Metric.time, settings.metrics_retention_days),
        ("connection_events", ConnectionEvent, ConnectionEvent.time, settings.connection_events_retention_days),
        (
            "service_state_history",
            ServiceStateHistory,
            ServiceStateHistory.time,
            settings.service_state_history_retention_days,
        ),
        ("notifications", Notification, Notification.created_at, settings.notifications_retention_days),
        ("plan_runs", PlanRun, PlanRun.started_at, settings.plan_runs_retention_days),
    ]
    deleted: dict[str, int] = {}
    for table_name, model, time_col, retention_days in plans:
        cutoff = now - timedelta(days=retention_days)
        result = await session.execute(delete(model).where(time_col < cutoff))
        await session.commit()
        deleted[table_name] = result.rowcount or 0
    return deleted


async def housekeeping_loop(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    stop_event: asyncio.Event,
    stats: HousekeepingStats | None = None,
) -> None:
    """Runs run_housekeeping on settings.housekeeping_interval_seconds
    until stop_event is set — the long-lived background task started
    from bossman.main's lifespan, mirroring poller_loop's shape."""
    while not stop_event.is_set():
        if settings.housekeeping_enabled:
            started = datetime.now(timezone.utc)
            try:
                async with session_factory() as session:
                    deleted = await run_housekeeping(session, settings, started)
                if stats is not None:
                    stats.last_run_at = started
                    stats.last_run_duration_ms = (datetime.now(timezone.utc) - started).total_seconds() * 1000
                    stats.deleted = deleted
                    stats.last_error = None
                total = sum(deleted.values())
                if total:
                    logger.info("housekeeping: deleted %d rows: %s", total, deleted)
            except Exception as exc:
                logger.exception("housekeeping run failed unexpectedly")
                if stats is not None:
                    stats.last_error = str(exc)

        try:
            await asyncio.wait_for(stop_event.wait(), timeout=settings.housekeeping_interval_seconds)
        except TimeoutError:
            pass
