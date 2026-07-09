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
from bossman.api.chunks import get_embedding_client
from bossman.config import Settings, get_settings
from bossman.db.models import Agent
from bossman.db.session import get_session
from bossman.services.agent_client import client_for
from bossman.services.catalog import CatalogCache
from bossman.services.embedding_client import EmbeddingClient
from bossman.services.plan_engine import run_plan
from bossman.services.plan_loader import Plan, PlanError, PlanStep, load_host_vars
from bossman.services.plan_search import index_plan_catalog, search_plans
from bossman.services.plan_store import VALID_PREFIXES, list_plans as store_list_plans, load_plan as store_load_plan, store_plan

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


class SearchPlansRequest(BaseModel):
    query: str
    top_k: int = 5
    threshold: float | None = None


class SearchPlanOut(BaseModel):
    name: str
    description: str
    similarity: float


class SearchPlansResponse(BaseModel):
    results: list[SearchPlanOut]


@router.post("/api/v1/plans/search", response_model=SearchPlansResponse)
async def search_plans_route(
    body: SearchPlansRequest,
    session: AsyncSession = Depends(get_session),
    cache: CatalogCache = Depends(get_catalog_cache),
    embedding_client: EmbeddingClient = Depends(get_embedding_client),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> SearchPlansResponse:
    """Embedding-based retrieval over the plan catalog (see docs/plan.md's
    "Plan-catalog RAG") — an alternative to scanning the full
    catalog_markdown/list_plans dump once the catalog grows past a
    handful of plans. Re-indexes any plan whose description changed since
    the last call (cheap after the first time, via index_plan_catalog's
    own content-hash short-circuit) before searching, so this route never
    needs a separate "reindex" step."""
    await index_plan_catalog(session, embedding_client, cache.plans)
    threshold = body.threshold if body.threshold is not None else settings.plan_search_threshold
    results = await search_plans(session, embedding_client, query=body.query, top_k=body.top_k, threshold=threshold)
    return SearchPlansResponse(
        results=[SearchPlanOut(name=r.name, description=r.description, similarity=r.similarity) for r in results]
    )


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


# --- Canonical plan store (docs/zielbestimmung.md) ----------------------
# The prefix-keyed JSONB store, addressable over HTTP. Distinct paths from
# the file-catalog routes above so both coexist during the transition to a
# single canonical store.


class StorePlanRequest(BaseModel):
    prefix: str  # ansible | salt | puppet | chef
    name: str
    source_format: str  # nestedtext | yaml | json (foreign DSLs as parsers land)
    source_text: str


class StoredPlanOut(BaseModel):
    prefix: str
    name: str
    version: int
    source_format: str
    content_hash: str


@router.get("/api/v1/plans/stored", response_model=list[StoredPlanOut])
async def list_stored_plans(
    prefix: str | None = None,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[StoredPlanOut]:
    if prefix is not None and prefix not in VALID_PREFIXES:
        raise HTTPException(status_code=400, detail=f"invalid prefix {prefix!r}")
    entries = await store_list_plans(session, prefix=prefix)
    return [StoredPlanOut(**{k: e[k] for k in ("prefix", "name", "version", "source_format", "content_hash")}) for e in entries]


@router.post("/api/v1/plans/stored", response_model=StoredPlanOut)
async def create_stored_plan(
    body: StorePlanRequest,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> StoredPlanOut:
    try:
        doc = await store_plan(
            session, body.prefix, body.name, body.source_format, body.source_text, created_by=identity.name
        )
    except PlanError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    await session.commit()
    return StoredPlanOut(
        prefix=doc.prefix, name=doc.name, version=doc.version, source_format=doc.source_format, content_hash=doc.content_hash
    )


@router.post("/api/v1/plans/stored/{prefix}/{name}/run", response_model=RunPlanResponse)
async def run_stored_plan_route(
    prefix: str,
    name: str,
    body: RunPlanRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> RunPlanResponse:
    """Run a plan from the canonical store (any prefix) against a host — the
    store counterpart of POST /api/v1/plans/{name}/run."""
    try:
        plan = await store_load_plan(session, prefix, name)
    except PlanError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    agent = await session.scalar(select(Agent).where(Agent.name == body.agent))
    if agent is None:
        raise HTTPException(status_code=404, detail=f"no such agent {body.agent!r}")
    if not agent.address:
        raise HTTPException(status_code=422, detail=f"agent {body.agent!r} has no reachable address")

    host_vars = load_host_vars(settings.plans_dir, agent.name)
    client = client_factory(agent, settings)
    try:
        plan_run = await run_plan(
            session, agent, plan, host_vars=host_vars, explicit_params=body.params,
            dry_run=body.dry_run, client=client, requested_by=identity.name,
        )
    except PlanError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return RunPlanResponse(plan_run_id=plan_run.id, status=plan_run.status)
