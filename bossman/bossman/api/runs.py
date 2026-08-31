"""GET /api/v1/runs, /api/v1/runs/{id} — the plan-run audit history (see
docs/plan.md's Bossman plan, section B.7): the Ansible-replacement audit
trail populated by services/plan_engine.run_plan.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from bossman.api.auth import get_current_identity
from bossman.db.models import PlanRun
from bossman.db.session import get_session

router = APIRouter()


class PlanRunOut(BaseModel):
    id: UUID
    plan_name: str
    plan_version: str | None
    agent_id: UUID
    params: dict[str, Any]
    dry_run: bool
    status: str
    started_at: datetime
    finished_at: datetime | None
    requested_by: str | None


class PlanRunStepOut(BaseModel):
    step_index: int
    step_name: str
    module: str | None
    request_body: dict[str, Any]
    response_body: dict[str, Any] | None
    changed: bool | None
    http_status: int | None
    error: str | None
    started_at: datetime
    finished_at: datetime | None


class PlanRunDetailOut(PlanRunOut):
    steps: list[PlanRunStepOut]


def _run_out(run: PlanRun) -> PlanRunOut:
    return PlanRunOut(
        id=run.id,
        plan_name=run.plan_name,
        plan_version=run.plan_version,
        agent_id=run.agent_id,
        params=run.params,
        dry_run=run.dry_run,
        status=run.status,
        started_at=run.started_at,
        finished_at=run.finished_at,
        requested_by=run.requested_by,
    )


@router.get("/api/v1/runs", response_model=list[PlanRunOut])
async def list_runs(
    agent_id: UUID | None = Query(None),
    plan_name: str | None = Query(None),
    status: str | None = Query(None),
    limit: int = Query(50, ge=1, le=500),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[PlanRunOut]:
    """Executions, newest first, whatever started them — a plan, a runbook, a schedule, a rollout.

    One place to answer "what has this system been doing", which is why the kind of thing that
    started a run is a field rather than a separate endpoint per source.
    """
    stmt = select(PlanRun)
    if agent_id is not None:
        stmt = stmt.where(PlanRun.agent_id == agent_id)
    if plan_name is not None:
        stmt = stmt.where(PlanRun.plan_name == plan_name)
    if status is not None:
        stmt = stmt.where(PlanRun.status == status)
    stmt = stmt.order_by(PlanRun.started_at.desc()).limit(limit)
    runs = (await session.scalars(stmt)).all()
    return [_run_out(r) for r in runs]


@router.get("/api/v1/runs/{run_id}", response_model=PlanRunDetailOut)
async def get_run(
    run_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> PlanRunDetailOut:
    """One execution with its per-step results and per-host outcomes. 404 for an unknown id."""
    run = await session.get(PlanRun, run_id, options=[selectinload(PlanRun.steps)])
    if run is None:
        raise HTTPException(status_code=404, detail=f"no such plan run {run_id}")
    steps = sorted(run.steps, key=lambda s: s.step_index)
    return PlanRunDetailOut(
        **_run_out(run).model_dump(),
        steps=[
            PlanRunStepOut(
                step_index=s.step_index,
                step_name=s.step_name,
                module=s.module,
                request_body=s.request_body,
                response_body=s.response_body,
                changed=s.changed,
                http_status=s.http_status,
                error=s.error,
                started_at=s.started_at,
                finished_at=s.finished_at,
            )
            for s in steps
        ],
    )
