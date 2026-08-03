"""Recurring runbook scheduler (fleet automation, gap #7).

A ScheduledJob is "run <runbook> against <scope> every <cron>". scheduler_loop
wakes each minute and fires jobs whose cron matches the current minute (guarding
against a double-fire within the same minute via last_run_at). Each fire runs the
runbook against every host in scope, honouring dry_run — reusing the exact
execute_runbook path the UI/CLI/MCP use, so a scheduled run is auditable like any
other.

Pure-ish: the loop owns its own sessions; fire_due_jobs is unit-testable with a
fixed `now` and an injected runner.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import Agent, ScheduledJob
from bossman.services import nt_runbook
from bossman.services.compiler import affected_agent_ids
from bossman.services.cron import cron_matches
from bossman.services.runbook_exec import execute_runbook

logger = logging.getLogger(__name__)


async def _run_job_on_scope(session: AsyncSession, settings: Settings, job: ScheduledJob, client_factory) -> tuple[str, str]:
    """Run job's runbook against every host in its scope. Returns
    (status, detail). Never raises."""
    from bossman.db.models import Runbook

    rb = await session.scalar(select(Runbook).where(Runbook.name == job.runbook_name))
    if rb is None:
        return "failed", f"no such runbook {job.runbook_name!r}"
    try:
        doc = nt_runbook.parse_data(rb.doc, source=f"runbook {job.runbook_name!r}")
    except Exception as exc:  # noqa: BLE001
        return "failed", f"runbook parse failed: {exc}"[:500]
    if not isinstance(doc, nt_runbook.Runbook):
        return "failed", f"{job.runbook_name!r} is a role, not a runbook"

    agent_ids = await affected_agent_ids(
        session, job.scope_type, ou_id=job.ou_id, agent_id=job.agent_id,
        host_group_id=job.host_group_id, tenant_id=job.tenant_id,
    )
    if not agent_ids:
        return "no-hosts", "scope matched no hosts"

    ok = failed = 0
    errors: list[str] = []
    for aid in agent_ids:
        agent = await session.get(Agent, aid)
        if agent is None or not agent.address:
            continue
        try:
            client = client_factory(agent, settings)
            _, rr = await execute_runbook(
                session, agent, doc, settings=settings, client=client,
                request_vars=dict(job.variables or {}), dry_run=job.dry_run,
                requested_by=f"scheduler:{job.name}", commit=False,
            )
            if rr.get("ok", True) and not rr.get("aborted"):
                ok += 1
            else:
                failed += 1
                errors.append(agent.name)
        except Exception as exc:  # noqa: BLE001 — one host must not sink the job
            failed += 1
            errors.append(f"{agent.name}: {str(exc)[:80]}")
    status = "ok" if failed == 0 else ("partial" if ok else "failed")
    detail = f"{ok} ok, {failed} failed" + (f" ({'; '.join(errors[:5])})" if errors else "")
    return status, detail


async def fire_due_jobs(
    session: AsyncSession, settings: Settings, now: datetime, client_factory,
) -> int:
    """Run every enabled job whose cron matches `now` (minute granularity) and
    that hasn't already run this minute. Returns the number fired."""
    jobs = (await session.scalars(select(ScheduledJob).where(ScheduledJob.enabled.is_(True)))).all()
    fired = 0
    minute_start = now.replace(second=0, microsecond=0)
    for job in jobs:
        try:
            if not cron_matches(job.cron, now):
                continue
        except Exception:  # noqa: BLE001 — a malformed cron must not stall others
            continue
        # Already ran this minute? (loop may tick more than once per minute)
        if job.last_run_at is not None and job.last_run_at >= minute_start:
            continue
        status, detail = await _run_job_on_scope(session, settings, job, client_factory)
        job.last_run_at = now
        job.last_status = status
        job.last_detail = detail[:2000]
        await session.commit()
        fired += 1
        logger.info("scheduled job %r fired: %s — %s", job.name, status, detail)
    return fired


async def scheduler_loop(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    stop_event: asyncio.Event,
    client_factory=None,
) -> None:
    """Fire due scheduled jobs each minute until stop_event is set. Sleeps to
    the next minute boundary so a job configured for HH:MM fires within that
    minute. Guarded by settings.scheduler_enabled (off in tests)."""
    if client_factory is None:
        from bossman.services.agent_client import client_for
        client_factory = client_for
    while not stop_event.is_set():
        if getattr(settings, "scheduler_enabled", True):
            try:
                async with session_factory() as session:
                    await fire_due_jobs(session, settings, datetime.now(timezone.utc), client_factory)
            except Exception:  # noqa: BLE001 — the scheduler must never crash the process
                logger.exception("scheduler tick failed")
        # Sleep to just past the next minute boundary.
        now = datetime.now(timezone.utc)
        await asyncio.sleep(max(5, 60 - now.second))
