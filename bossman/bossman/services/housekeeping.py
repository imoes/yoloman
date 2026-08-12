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

from uuid import UUID

from bossman.config import Settings
from bossman.db.models import (
    SYSTEM_SETTINGS_ID,
    AuditLog,
    Notification,
    PlanRun,
    RunbookRun,
    SystemSettings,
)

logger = logging.getLogger(__name__)


# Series pruned per statement. Small on purpose: a large IN-list against a
# hypertable makes TimescaleDB decompress broadly, which is what blew the
# `max_tuples_decompressed_per_dml_transaction` limit (100k) before.
_PRUNE_BATCH = 500
# Cap per run so one housekeeping tick cannot hold the DB busy indefinitely on a
# huge backlog; the remainder is picked up on the next tick.
_PRUNE_MAX_BATCHES = 200


@dataclass
class HousekeepingStats:
    """Last-run outcome, surfaced by GET /api/v1/admin/diagnostics (Block
    K2) — mirrors Zabbix's housekeeper diagnostics."""

    last_run_at: datetime | None = None
    last_run_duration_ms: float | None = None
    deleted: dict[str, int] = field(default_factory=dict)
    last_error: str | None = None


async def prune_process_series(
    session: AsyncSession, settings: Settings, now: datetime,
) -> dict[str, int]:
    """Delete series of processes that have died — the FAST path.

    Split out of run_housekeeping and given its own loop on purpose: the stale
    THRESHOLD (process_metric_stale_minutes, 1 min) is useless if the SWEEP only
    runs hourly. Measured on the live fleet after the threshold was lowered to a
    minute: 1448 process series of which only 338 were alive — 1110 corpses were
    sitting around waiting for the next hourly pass. Frequency, not the threshold,
    is what keeps per-PID cardinality down.
    """
    # process_*
    # metrics are per (pid, comm): a dead pid stops updating, so deleting its
    # series shortly after death keeps per-pid churn from reaching the compressed
    # chunks where tiny segments would hurt compression.
    #
    # WHY THIS IS TWO PHASES AND BATCHED (the bug this replaces):
    # the previous version deleted the metric_series row straight away and let the
    # FK ON DELETE CASCADE remove the points. But a cascade carries NO time
    # predicate, so its DML against metrics_raw reaches every chunk including the
    # compressed ones, TimescaleDB decompresses to satisfy it, and the statement
    # aborted every single run with "tuple decompression limit exceeded ... tuples
    # decompressed: 7745320". The guard below (no point older than compress_after)
    # picked the right SERIES but could not limit the CASCADE's reach. Result:
    # nothing was ever pruned — 79 946 of 80 774 process series were stale, 81% of
    # all cardinality, and the retries also inline-decompressed a chunk to 1150 MB.
    #
    # So: delete the points FIRST with an explicit `time >= floor`, which lets
    # chunk exclusion skip the compressed chunks entirely; then delete the series,
    # which by now owns no points, so the cascade finds nothing to do. Batched, so
    # no single statement can approach the decompression limit even if a series
    # turns out to have older points after all.
    stale_cutoff = now - timedelta(minutes=settings.process_metric_stale_minutes)
    uncompressed_floor = now - timedelta(days=1)
    # Belt and braces for the planner behaviour behind the bug above (upstream
    # timescale/timescaledb#9916): after five parameterized executions PostgreSQL
    # switches the cached plan to GENERIC, and on a compressed hypertable that plan
    # decompresses everything instead of seeking the segmentby column — which is why
    # the failure decompressed an identical 4,134,419 tuples whether the batch held
    # 10 ids or 250. Forcing custom plans keeps each execution planned against its
    # actual parameters. Session-scoped, so it cannot affect other queries.
    try:
        await session.execute(text("SET LOCAL plan_cache_mode = force_custom_plan"))
    except Exception:  # noqa: BLE001 — older PG without the GUC: the fix above stands alone
        logger.debug("plan_cache_mode not settable; relying on the non-cascading delete path")
    pruned = 0
    batches = 0
    prune_error: str | None = None
    while True:
        try:
            ids = (await session.execute(
                text(
                    """
                    SELECT s.series_id FROM metric_series s
                    WHERE s.metric IN ('process_cpu_percent', 'process_rss_bytes')
                      AND NOT EXISTS (
                        SELECT 1 FROM metrics_raw r
                        WHERE r.series_id = s.series_id AND r.time >= :cutoff)
                      AND NOT EXISTS (
                        SELECT 1 FROM metrics_raw r
                        WHERE r.series_id = s.series_id AND r.time < :floor)
                    LIMIT :batch
                    """
                ),
                {"cutoff": stale_cutoff, "floor": uncompressed_floor,
                 "batch": _PRUNE_BATCH},
            )).scalars().all()
            if not ids:
                break
            # phase 1: the points, time-bounded → compressed chunks are excluded
            await session.execute(
                text("DELETE FROM metrics_raw WHERE series_id = ANY(:ids) AND time >= :floor"),
                {"ids": list(ids), "floor": uncompressed_floor},
            )
            # phase 2: the (now point-less) series rows. Guard each delete with a
            # time-bounded NOT EXISTS so a series that gained a referencing point
            # between phase 1 and here (a concurrent insert, or a straggler) is
            # SKIPPED instead of aborting the whole prune on the FK
            # (metrics_raw_series_id_fkey). Same `>= floor` bound as phase 1, so the
            # check stays on uncompressed chunks (no decompression). Skipped series
            # are simply pruned on a later run.
            res = await session.execute(
                text(
                    "DELETE FROM metric_series WHERE series_id = ANY(:ids) "
                    "AND NOT EXISTS (SELECT 1 FROM metrics_raw r "
                    "WHERE r.series_id = metric_series.series_id AND r.time >= :floor)"
                ),
                {"ids": list(ids), "floor": uncompressed_floor},
            )
            await session.commit()
            pruned += res.rowcount or 0
            batches += 1
            if batches >= _PRUNE_MAX_BATCHES:
                logger.warning(
                    "process-stale prune hit the per-run batch cap (%d batches, %d series pruned); "
                    "more remain and will go on the next run", batches, pruned)
                break
        except Exception as exc:  # noqa: BLE001 — never let the prune abort retention
            await session.rollback()
            prune_error = f"{type(exc).__name__}: {exc}"
            # Log the CAUSE, not just "failed": this exact failure went unnoticed for
            # days because the old message said nothing and buried the reason in a
            # traceback nobody greps for.
            logger.error(
                "process-stale prune FAILED after %d batch(es), %d series pruned — %s",
                batches, pruned, prune_error, exc_info=True)
            break
    return {"process_series_stale": pruned}


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

    # Event/run history retention (gap #13, Event Browser): unlike the two above
    # this window is DB-backed and operator-set from the Admin settings UI
    # (SystemSettings.run_retention_days), so it's read live each pass rather than
    # from the env-config. 0 = keep forever (skip). Covers both the play log
    # (runbook_runs) and the who-did-what audit trail (audit_log).
    ss = await session.get(SystemSettings, UUID(SYSTEM_SETTINGS_ID))
    run_retention = ss.run_retention_days if ss else 0
    if run_retention and run_retention > 0:
        event_cutoff = now - timedelta(days=run_retention)
        for table_name, model, time_col in (
            ("runbook_runs", RunbookRun, RunbookRun.created_at),
            ("audit_log", AuditLog, AuditLog.at),
        ):
            res = await session.execute(delete(model).where(time_col < event_cutoff))
            await session.commit()
            deleted[table_name] = res.rowcount or 0

    # The fast per-PID prune (also driven by its own loop — see
    # process_prune_loop, because hourly is far too slow for PID churn).
    deleted.update(await prune_process_series(session, settings, now))

    # Sweep remaining orphan series (no points at all — e.g. their chunks were
    # dropped by retention). Batched for the same reason as above.
    orphans = 0
    try:
        while True:
            res = await session.execute(
                text(
                    """
                    DELETE FROM metric_series WHERE series_id IN (
                      SELECT s.series_id FROM metric_series s
                      WHERE NOT EXISTS (
                        SELECT 1 FROM metrics_raw r WHERE r.series_id = s.series_id)
                      LIMIT :batch)
                    """
                ),
                {"batch": _PRUNE_BATCH},
            )
            await session.commit()
            n = res.rowcount or 0
            orphans += n
            if n < _PRUNE_BATCH:
                break
    except Exception as exc:  # noqa: BLE001
        await session.rollback()
        logger.error("metric_series orphan sweep FAILED after %d series — %s: %s",
                     orphans, type(exc).__name__, exc, exc_info=True)
    deleted["metric_series_orphans"] = orphans

    # Report the outcome even when it is zero — a silent "nothing to do" is
    # indistinguishable from a silent failure, which is how the bug above hid.
    remaining = (await session.execute(
        text("SELECT count(*) FROM metric_series")
    )).scalar_one()
    # `pruned`/`batches`/`prune_error` used to be read here as locals — they moved into
    # prune_process_series() when it was extracted, so this line raised
    # NameError: name 'pruned' is not defined and took the WHOLE housekeeping run with
    # it, on every single tick. Exactly the failure mode the comment above warns about:
    # the log line meant to prove the prune ran was itself what stopped it. The count
    # now comes from the returned dict, which is the only thing this scope can see.
    logger.info(
        "housekeeping: process_series_stale=%d orphans=%d metric_series_remaining=%d",
        deleted.get("process_series_stale", 0), orphans, remaining)

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


async def process_prune_loop(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    stop_event: asyncio.Event,
) -> None:
    """Runs prune_process_series on its own short interval.

    Separate from housekeeping_loop because the two have completely different
    natural frequencies: retention only needs an hourly pass, while per-PID series
    churn continuously and must be collected within minutes to keep cardinality —
    and therefore the aggregates and the DB size — bounded.
    """
    while not stop_event.is_set():
        if settings.housekeeping_enabled:
            try:
                async with session_factory() as session:
                    res = await prune_process_series(session, settings, datetime.now(timezone.utc))
                if res.get("process_series_stale"):
                    logger.info("process prune: %d dead series removed", res["process_series_stale"])
            except Exception:  # noqa: BLE001 — a failed pass must not kill the loop
                logger.exception("process prune pass failed")
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=settings.process_prune_interval_seconds)
            return
        except asyncio.TimeoutError:
            continue
