"""Scheduled jobs CRUD + run-now (gap #7): recurring runbook runs on a cron
schedule, scoped to a host / group / OU. The scheduler_loop fires them; this is
the management surface.
"""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import ScheduledJob
from bossman.db.session import get_session

router = APIRouter()
DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")
_SCOPES = ("host", "group", "ou")


class ScheduledJobIn(BaseModel):
    name: str
    enabled: bool = True
    cron: str
    runbook_name: str
    scope_type: str
    agent_id: UUID | None = None
    host_group_id: UUID | None = None
    ou_id: UUID | None = None
    variables: dict = {}
    dry_run: bool = False


class ScheduledJobOut(ScheduledJobIn):
    id: UUID
    last_run_at: datetime | None = None
    last_status: str | None = None
    last_detail: str | None = None
    created_at: datetime

    @classmethod
    def of(cls, j: ScheduledJob) -> "ScheduledJobOut":
        return cls(
            id=j.id, name=j.name, enabled=j.enabled, cron=j.cron, runbook_name=j.runbook_name,
            scope_type=j.scope_type, agent_id=j.agent_id, host_group_id=j.host_group_id, ou_id=j.ou_id,
            variables=j.variables or {}, dry_run=j.dry_run, last_run_at=j.last_run_at,
            last_status=j.last_status, last_detail=j.last_detail, created_at=j.created_at,
        )


def _validate(body: ScheduledJobIn) -> None:
    from bossman.services.cron import is_valid_cron

    if body.scope_type not in _SCOPES:
        raise HTTPException(422, f"scope_type must be one of {'|'.join(_SCOPES)}")
    if not is_valid_cron(body.cron):
        raise HTTPException(422, f"invalid cron expression: {body.cron!r} (need 5 fields)")
    target = {"host": body.agent_id, "group": body.host_group_id, "ou": body.ou_id}[body.scope_type]
    if target is None:
        raise HTTPException(422, f"scope_type={body.scope_type} needs its target id")
    if not body.name.strip() or not body.runbook_name.strip():
        raise HTTPException(422, "name and runbook_name are required")


@router.get("/api/v1/scheduled-jobs", response_model=list[ScheduledJobOut])
async def list_jobs(session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    """Recurring runbook runs: what fires when, where, and how the last run went.

    A job is a runbook plus a cron schedule plus a scope (host, group, OU). The scheduler loop fires
    them; this is the management surface, so an entry here is a *declaration* and its last outcome is
    the evidence that it works.
    """
    rows = (await session.scalars(select(ScheduledJob).order_by(ScheduledJob.name))).all()
    return [ScheduledJobOut.of(j) for j in rows]


@router.post("/api/v1/scheduled-jobs", response_model=ScheduledJobOut)
async def create_job(body: ScheduledJobIn, session: AsyncSession = Depends(get_session),
                     identity: Identity = Depends(get_current_identity)):
    """Schedule a runbook. Nothing runs on creation.

    The scope is resolved **at fire time**, not now — a host that joins the group later is included,
    which is usually the point of a recurring job and occasionally a surprise. Use `.../run` to fire
    it once by hand without touching the schedule.
    """
    _validate(body)
    job = ScheduledJob(tenant_id=DEFAULT_TENANT_ID, created_by=identity.name, **body.model_dump())
    session.add(job)
    await session.commit()
    await session.refresh(job)
    return ScheduledJobOut.of(job)


@router.put("/api/v1/scheduled-jobs/{job_id}", response_model=ScheduledJobOut)
async def update_job(job_id: UUID, body: ScheduledJobIn, session: AsyncSession = Depends(get_session),
                     _i: Identity = Depends(get_current_identity)):
    """Replace a scheduled job. A run already in flight is unaffected; the next firing uses the new
    definition. 404 for an unknown id."""
    _validate(body)
    job = await session.get(ScheduledJob, job_id)
    if job is None:
        raise HTTPException(404, "no such scheduled job")
    for field, value in body.model_dump().items():
        setattr(job, field, value)
    await session.commit()
    await session.refresh(job)
    return ScheduledJobOut.of(job)


@router.delete("/api/v1/scheduled-jobs/{job_id}", status_code=204)
async def delete_job(job_id: UUID, session: AsyncSession = Depends(get_session),
                     _i: Identity = Depends(get_current_identity)):
    """Delete a scheduled job.

    Its run history stays: what ran must remain explainable after the schedule that caused it is
    gone. If you only want it to stop, disable it instead and keep the link intact.
    """
    job = await session.get(ScheduledJob, job_id)
    if job is not None:
        await session.delete(job)
        await session.commit()


@router.post("/api/v1/scheduled-jobs/{job_id}/run-now", response_model=ScheduledJobOut)
async def run_now(job_id: UUID, session: AsyncSession = Depends(get_session),
                  settings: Settings = Depends(get_settings), _i: Identity = Depends(get_current_identity),
                  client_factory=Depends(get_client_factory)):
    """Fire a scheduled job immediately (ignoring its cron), against its scope."""
    from bossman.services.scheduler import _run_job_on_scope

    job = await session.get(ScheduledJob, job_id)
    if job is None:
        raise HTTPException(404, "no such scheduled job")
    status, detail = await _run_job_on_scope(session, settings, job, client_factory)
    job.last_run_at = datetime.now(timezone.utc)
    job.last_status = status
    job.last_detail = detail[:2000]
    await session.commit()
    await session.refresh(job)
    return ScheduledJobOut.of(job)
