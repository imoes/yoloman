"""GET /api/v1/plans, /api/v1/plans/{name}, POST /api/v1/plans/{name}/run
— the "take plan X, run it against host Y" surface (see docs/plan.md's
Bossman plan, section B.7): this is what turns the whole Nordstern-UX goal
("nimm Plan xy und führe ihn gegen Host z aus") into one HTTP call.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.models import Agent
from bossman.db.session import get_session
from bossman.services.agent_client import client_for
from bossman.services.catalog import CatalogCache
from bossman.services.plan_engine import run_plan
from bossman.services.plan_loader import Plan, PlanError, PlanStep, load_host_vars

router = APIRouter()


async def get_catalog_cache(request: Request) -> CatalogCache:
    return request.app.state.catalog_cache


def get_client_factory():
    """Overridable in tests via app.dependency_overrides to substitute a
    fake AgentClient instead of a real network connection — the FastAPI-
    native counterpart of the client_factory test seam services/poller.py
    already uses."""
    return client_for


class PlanParamOut(BaseModel):
    type: str
    required: bool
    pattern: str | None
    default: Any | None


class PlanOut(BaseModel):
    name: str
    description: str
    params: dict[str, PlanParamOut]


class PlanDetailOut(PlanOut):
    steps: list[dict[str, Any]]


def _plan_out(plan: Plan) -> PlanOut:
    return PlanOut(
        name=plan.name,
        description=plan.description,
        params={
            name: PlanParamOut(type=spec.type, required=spec.required, pattern=spec.pattern, default=spec.default)
            for name, spec in plan.params.items()
        },
    )


def _step_out(step: PlanStep) -> dict[str, Any]:
    return {
        "name": step.name,
        "kind": step.kind,
        "check_mode": step.check_mode,
        "on_failure": step.on_failure,
        "module": step.module,
        "body": step.body,
        "pipeline": step.pipeline,
        "upload_local_path": step.upload_local_path,
        "upload_remote_name": step.upload_remote_name,
    }


def _find_plan_or_404(cache: CatalogCache, name: str) -> Plan:
    plan = cache.get(name)
    if plan is None:
        raise HTTPException(status_code=404, detail=f"no such plan {name!r}")
    return plan


@router.get("/api/v1/plans", response_model=list[PlanOut])
async def list_plans(
    cache: CatalogCache = Depends(get_catalog_cache),
    _identity=Depends(get_current_identity),
) -> list[PlanOut]:
    return [_plan_out(p) for p in cache.plans]


@router.get("/api/v1/plans/{name}", response_model=PlanDetailOut)
async def get_plan(
    name: str,
    cache: CatalogCache = Depends(get_catalog_cache),
    _identity=Depends(get_current_identity),
) -> PlanDetailOut:
    plan = _find_plan_or_404(cache, name)
    return PlanDetailOut(**_plan_out(plan).model_dump(), steps=[_step_out(s) for s in plan.steps])


class ReloadResponse(BaseModel):
    reloaded: bool
    catalog_length: int


@router.post("/api/v1/plans/reload", response_model=ReloadResponse)
async def reload_plans(
    cache: CatalogCache = Depends(get_catalog_cache),
    _identity=Depends(get_current_identity),
) -> ReloadResponse:
    """Re-renders the MCP facade's static plan-catalog text from disk (see
    services/catalog.py) — the only thing that invalidates it. Anthropic
    prompt caching needs that text byte-identical across calls, so it is
    never re-rendered per request, only on this explicit operator action."""
    text = cache.reload()
    return ReloadResponse(reloaded=True, catalog_length=len(text))


class RunPlanRequest(BaseModel):
    # Matches Agent.name — mirrors the MCP facade design's
    # run_plan(plan, host, params, dry_run) signature (docs/plan.md,
    # Bossman plan section B.6): a host is named, not id-addressed, since
    # that's what a human/AI caller actually knows.
    agent: str
    params: dict[str, Any] = {}
    dry_run: bool = False


class RunPlanResponse(BaseModel):
    plan_run_id: UUID
    status: str


@router.post("/api/v1/plans/{name}/run", response_model=RunPlanResponse)
async def run_plan_route(
    name: str,
    body: RunPlanRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    cache: CatalogCache = Depends(get_catalog_cache),
    identity=Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> RunPlanResponse:
    plan = _find_plan_or_404(cache, name)

    agent = await session.scalar(select(Agent).where(Agent.name == body.agent))
    if agent is None:
        raise HTTPException(status_code=404, detail=f"no such agent {body.agent!r}")
    if not agent.address:
        raise HTTPException(status_code=422, detail=f"agent {body.agent!r} has no reachable address")

    host_vars = load_host_vars(settings.plans_dir, agent.name)
    client = client_factory(agent, settings)

    try:
        plan_run = await run_plan(
            session,
            agent,
            plan,
            host_vars=host_vars,
            explicit_params=body.params,
            dry_run=body.dry_run,
            client=client,
            requested_by=identity.name,
        )
    except PlanError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    return RunPlanResponse(plan_run_id=plan_run.id, status=plan_run.status)
