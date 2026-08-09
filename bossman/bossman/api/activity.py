"""Live activity feed for the header Event-Console badge.

The Event Browser (gap #13) shows FINISHED plays (runbook_runs are persisted on
completion), but the operator also wants an at-a-glance count of what is running
RIGHT NOW in the top-right corner. Those live jobs live in three tables that DO
carry an in-flight status: plan runs, PXE restore jobs, and fleet rollouts. This
endpoint aggregates their running/pending rows into one small, cheap payload the
header polls.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import PlanRun, RestoreJob, Rollout
from bossman.db.session import get_session

router = APIRouter()


@router.get("/api/v1/activity/running")
async def running_activity(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Count + a small list of currently in-flight jobs (plan runs, PXE restores,
    rollouts). Drives the header Event-Console badge — `count` is the badge number,
    `jobs` a preview for the hover/click-through."""
    jobs: list[dict[str, Any]] = []

    for r in (await session.scalars(
        select(PlanRun).where(PlanRun.status == "running").order_by(PlanRun.started_at.desc()).limit(50)
    )).all():
        jobs.append({"kind": "plan", "id": str(r.id), "name": r.plan_name,
                     "status": r.status, "since": r.started_at.isoformat() if r.started_at else None})

    for r in (await session.scalars(
        select(RestoreJob).where(RestoreJob.status.in_(("pending", "running")))
        .order_by(RestoreJob.created_at.desc()).limit(50)
    )).all():
        jobs.append({"kind": "restore", "id": str(r.id), "name": r.target_hostname,
                     "status": r.status, "since": (r.started_at or r.created_at).isoformat()})

    for r in (await session.scalars(
        select(Rollout).where(Rollout.status == "running").order_by(Rollout.id.desc()).limit(50)
    )).all():
        jobs.append({"kind": "rollout", "id": str(r.id), "name": r.runbook_name,
                     "status": r.status, "since": r.started_at.isoformat() if r.started_at else None})

    return {"count": len(jobs), "jobs": jobs}
