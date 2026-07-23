"""Configurable, on-demand data retention (Zabbix gap-analysis Block K1):
Zabbix's housekeeper is a dedicated, configurable, runtime-triggerable
server process (`housekeeper_execute`).

**Correction (same session, Batch 2 decision round):** the initial version
of this module also deleted rows from `metrics`, `connection_events`, and
`service_state_history` — but those three are TimescaleDB hypertables that
*already* have native `add_retention_policy(...)` background jobs
registered at migration time (14/30/30 days respectively — see
alembic/versions/f17d664762b0_initial_schema.py and
50e78cc78c2a_monitoring_core.py). Re-deleting them here in Python was
redundant at best and misleading at worst: changing
`settings.metrics_retention_days` would have had **no actual effect**,
since TimescaleDB's own policy — configured independently at the DB level
— would still win. This module is now scoped to the two tables that
genuinely had no retention at all: `notifications` and `plan_runs`. The
three hypertables' retention is TimescaleDB-native and out of Python's
control; `metrics`'s longer-term story is the `metrics_hourly`/
`metrics_daily` continuous aggregates (Block K1b), not this module.

Framework-free (no FastAPI import), like services/poller.py, so it's
reachable from the app's background task, the admin route, and tests
without duplicating logic.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import Notification, PlanRun

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
    table doesn't roll back cleanup already done on the others.

    Scoped to `notifications`/`plan_runs` only — metrics/connection_events/
    service_state_history are TimescaleDB hypertables with their own
    native retention policies (see module docstring)."""
    plans = [
        ("notifications", Notification, Notification.created_at, settings.notifications_retention_days),
        ("plan_runs", PlanRun, PlanRun.started_at, settings.plan_runs_retention_days),
    ]
    deleted: dict[str, int] = {}
    for table_name, model, time_col, retention_days in plans:
        cutoff = now - timedelta(days=retention_days)
        result = await session.execute(delete(model).where(time_col < cutoff))
        await session.commit()
        deleted[table_name] = result.rowcount or 0

    # Freshness cleanup of dead process series. process_cpu_percent /
    # process_rss_bytes are keyed per (pid, comm): a restart mints a new pid, so
    # the old pid's series stops updating. Delete any such series whose newest
    # sample is stale (the process is gone) rather than waiting out raw
    # retention — a live process samples every collect interval, so it is never
    # matched. This is the CONTROL-PLANE cleanup: Postgres holds the real
    # long-term data (the agent keeps only a short-lived local copy it serves
    # from), so the lifecycle of this data belongs here, next to retention.
    # Only delete from UNCOMPRESSED chunks. TimescaleDB raises
    # "tuple decompression limit exceeded" when a DML touches a compressed
    # row group. Compressed chunks are dropped by the 2-day retention policy
    # anyway; stale dead-(pid,comm) series only need pruning from the current
    # uncompressed chunk (today's live data written since the last compression).
    stale_cutoff = now - timedelta(minutes=settings.process_metric_stale_minutes)
    res = await session.execute(
        text(
            """
            DELETE FROM metrics
            WHERE time >= (
                SELECT COALESCE(min(range_start), 'epoch'::timestamptz)
                FROM timescaledb_information.chunks
                WHERE hypertable_name = 'metrics' AND is_compressed = false
            )
              AND metric IN ('process_cpu_percent', 'process_rss_bytes')
              AND (agent_id, metric, labels) IN (
                SELECT agent_id, metric, labels
                FROM metrics
                WHERE metric IN ('process_cpu_percent', 'process_rss_bytes')
                  AND time >= (
                    SELECT COALESCE(min(range_start), 'epoch'::timestamptz)
                    FROM timescaledb_information.chunks
                    WHERE hypertable_name = 'metrics' AND is_compressed = false
                  )
                GROUP BY agent_id, metric, labels
                HAVING max(time) < :cutoff
              )
            """
        ),
        {"cutoff": stale_cutoff},
    )
    await session.commit()
    deleted["metrics_process_stale"] = res.rowcount or 0
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
