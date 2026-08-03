"""GET /api/v1/plans, /api/v1/plans/{name}, POST /api/v1/plans/{name}/run
— the "take plan X, run it against host Y" surface (see docs/plan.md's
Bossman plan, section B.7): this is what turns the whole Nordstern-UX goal
("nimm Plan xy und führe ihn gegen Host z aus") into one HTTP call.
"""

from __future__ import annotations

import json
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.services.auth import user_can_manage_agent
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
from bossman.services.plan_store import (
    VALID_PREFIXES,
    canonical_from_source,
    detect_plan_format,
    plan_name_from_path,
    delete_plan as store_delete_plan,
    import_plans_dir as store_import_plans_dir,
    list_plans as store_list_plans,
    load_plan as store_load_plan,
    store_plan,
)
from bossman.services import plan_library
from bossman.services.ansible_playbook import parse_playbook
from bossman.services.nt_convert import doc_to_nt, doc_to_yaml
from bossman.services.chat_client import ChatClient, ChatClientError
from bossman.db.models import DEFAULT_TENANT_ID, PlanDocument, Runbook

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


class PlanBriefingOut(BaseModel):
    """AI briefing shown above the run form (mirrors the chat's md+UML
    doctrine): what the task does, per-parameter guidance, and — when the
    model judges it useful — a ```plantuml``` flow diagram. `markdown` is
    None with `error` set when the LLM is unavailable; the form still works."""

    markdown: str | None
    error: str | None = None


_BRIEFING_SYSTEM = (
    "You brief an operator who is about to run an automation task on a host. "
    "You are given the plan: its steps and its parameters. Produce a concise "
    "Markdown briefing, in this order:\n"
    "1. One or two sentences on what the task does overall.\n"
    "2. A short bullet for each parameter the operator must set — what it "
    "controls and a sensible value; mark the required ones. Skip this if the "
    "task has no parameters.\n"
    "3. Explicitly call out any step that WRITES or changes the system, so the "
    "operator knows what a real (non-dry-run) apply will do.\n"
    "DECIDE YOURSELF whether a diagram helps: if the task is a multi-step or "
    "branching flow, include exactly ONE ```plantuml``` activity or sequence "
    "diagram of the execution order; if it is a single trivial step, use prose "
    "only and do NOT force a diagram. Be terse — this sits above the input "
    "form the operator is about to fill in. Do not ask questions."
)


def _briefing_payload(plan: Plan) -> dict[str, Any]:
    """Compact plan view for the briefing LLM — steps by name/kind/module and
    the parameter specs, without the full step bodies (which bloat the prompt
    and rarely change the operator-facing explanation)."""
    return {
        "name": plan.name,
        "description": plan.description,
        "parameters": {
            name: {"type": spec.type, "required": spec.required, "default": spec.default}
            for name, spec in plan.params.items()
        },
        "steps": [
            {"name": s.name, "kind": s.kind, "module": s.module, "on_failure": s.on_failure}
            for s in plan.steps
        ],
    }


@router.post("/api/v1/plans/{name}/briefing", response_model=PlanBriefingOut)
async def plan_briefing(
    name: str,
    cache: CatalogCache = Depends(get_catalog_cache),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> PlanBriefingOut:
    plan = _find_plan_or_404(cache, name)
    # A tighter timeout than the chat's — this blocks the run dialog, so we'd
    # rather fall back to a form-only view than hang on an overloaded endpoint.
    client = ChatClient(
        base_url=settings.chat_base_url, model=settings.chat_model,
        token=settings.chat_token, timeout=90.0,
    )
    messages = [
        {"role": "system", "content": _BRIEFING_SYSTEM},
        {"role": "user", "content": json.dumps(_briefing_payload(plan), indent=2)},
    ]
    try:
        text = await client.complete_text(
            messages,
            extra_body={"chat_template_kwargs": {"enable_thinking": False}},
        )
    except ChatClientError as exc:
        return PlanBriefingOut(markdown=None, error=str(exc)[:300])
    return PlanBriefingOut(markdown=text.strip())


class ReloadResponse(BaseModel):
    reloaded: bool
    catalog_length: int


@router.post("/api/v1/plans/reload", response_model=ReloadResponse)
async def reload_plans(
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    cache: CatalogCache = Depends(get_catalog_cache),
    _identity=Depends(get_current_identity),
) -> ReloadResponse:
    """Re-imports plans_dir into the canonical store (docs/zielbestimmung.md
    #5 — keeping the store in sync with the authoring dir) and re-renders the
    MCP facade's static plan-catalog text from disk. Anthropic prompt caching
    needs that text byte-identical across calls, so it is never re-rendered
    per request, only on this explicit operator action."""
    try:
        await store_import_plans_dir(session, settings.plans_dir)
        await session.commit()
    except PlanError:
        await session.rollback()  # a malformed authoring file shouldn't block the cache refresh
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
    if not await user_can_manage_agent(session, identity, agent.id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
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


class BulkFile(BaseModel):
    """One file of a directory import: its path (relative, as the browser reports it) and its text."""
    path: str
    text: str


class BulkImportRequest(BaseModel):
    files: list[BulkFile]
    folder: str = ""            # ltree folder the imported plans land in
    dry_run: bool = False       # report what WOULD be imported, touch nothing


class BulkImportResult(BaseModel):
    imported: list[dict] = []   # [{path, prefix, name, version, kind}] — kind ∈ runbook|plan, see below
    skipped: list[dict] = []    # [{path, reason}] — not a plan we can parse
    failed: list[dict] = []     # [{path, error}]  — recognised but the parser refused it


@router.post("/api/v1/plans/import-bulk", response_model=BulkImportResult)
async def import_plans_bulk(
    body: BulkImportRequest,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> BulkImportResult:
    """Import a whole directory of foreign orchestration sources — Ansible, Salt, Puppet, Chef — in one call.

    A checked-out role/cookbook tree is mostly NOT plans (templates, defaults, metadata, fixtures), so each
    file is classified first (services/plan_store.detect_plan_format) and anything unrecognised is SKIPPED
    with a reason instead of failing the import. One unparseable file likewise lands in `failed` and the rest
    still import — a 400-file tree must not be lost because file 3 is exotic.

    `dry_run` classifies without writing, so the operator can see what a tree would produce first.
    """
    out = BulkImportResult()
    for f in body.files:
        spec = detect_plan_format(f.path)
        if spec is None:
            out.skipped.append({"path": f.path, "reason": "not a recognised plan file"})
            continue
        prefix, fmt = spec
        name = plan_name_from_path(f.path)

        # Ansible task files go to the RUNBOOK store, not the plan store. The two engines have different
        # surfaces: a runbook carries Ansible's full task vocabulary (block/rescue/always, notify, tags,
        # become, failed_when/changed_when, key=value free-form), a plan carries the narrower
        # pipeline/upload/assert shape. Measured on geerlingguy.nginx: the runbook parser takes 10 of 10 task
        # files, the plan loader 4 — so routing a role through the plan store would refuse most of real
        # upstream Ansible for no reason. Salt/Puppet/Chef keep going to the plan store (their parsers emit
        # plan bodies).
        if prefix == "ansible" and fmt in ("yaml", "yml"):
            try:
                doc = parse_playbook(f.text).to_dict()
                doc["name"] = name
                if not body.dry_run:
                    existing = await session.scalar(
                        select(Runbook).where(Runbook.tenant_id == DEFAULT_TENANT_ID, Runbook.name == name))
                    if existing is None:
                        session.add(Runbook(tenant_id=DEFAULT_TENANT_ID, name=name, kind="runbook",
                                            folder=(body.folder or "").strip("/"), doc=doc,
                                            created_by=identity.name))
                    else:
                        existing.doc = doc          # re-importing the same tree updates, it does not 409
                out.imported.append({"path": f.path, "prefix": prefix, "name": name, "version": 1,
                                     "kind": "runbook"})
            except Exception as exc:  # noqa: BLE001 — per-file isolation, see below
                out.failed.append({"path": f.path, "error": f"{type(exc).__name__}: {exc}"[:300]})
            continue

        try:
            if body.dry_run:
                # A preview must still PARSE, otherwise it reports files as importable that the real run then
                # rejects — the whole point of the preview is seeing the failures before writing anything.
                canonical_from_source(fmt, f.text, name=name)
                out.imported.append({"path": f.path, "prefix": prefix, "name": name, "version": 0,
                                     "kind": "plan"})
                continue
            doc = await store_plan(session, prefix, name, fmt, f.text, created_by=identity.name)
            if body.folder:
                await plan_library.set_placement(session, prefix, name, body.folder)
            out.imported.append({"path": f.path, "prefix": prefix, "name": name, "version": doc.version,
                                 "kind": "plan"})
        except Exception as exc:  # noqa: BLE001 — deliberately broad, see below
            # Per-file failure: keep going. A 400-file tree must not be lost because one file is exotic, and
            # the foreign parsers raise their OWN exception types (PlaybookError, NTRunbookError, and
            # whatever a DSL parser throws on malformed input) — catching only PlanError let one bad file
            # 500 the entire request, which is how this was found. The report names the file and the reason,
            # so nothing is swallowed silently.
            out.failed.append({"path": f.path, "error": f"{type(exc).__name__}: {exc}"[:300]})
    if not body.dry_run and out.imported:
        await session.commit()
    return out


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


# ---- Plan library: folder tree + format views (ltree + Monaco) -----------


class MovePlanRequest(BaseModel):
    folder: str  # human path, e.g. "linux/base" ("" = root)


@router.get("/api/v1/plan-library")
async def plan_library_list(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Every stored plan/role (latest version) with its folder placement, for
    the plan-library tree. Un-placed plans report folder "" (root)."""
    plans = await store_list_plans(session)
    folders = await plan_library.placement_map(session)
    for p in plans:
        p["folder"] = folders.get((p["prefix"], p["name"]), "")
    return {"plans": plans, "folders": sorted({f for f in folders.values() if f})}


@router.delete("/api/v1/plans/stored/{prefix}/{name}")
async def delete_stored_plan(
    prefix: str,
    name: str,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Delete a stored plan (all versions + its folder placement)."""
    if prefix not in VALID_PREFIXES:
        raise HTTPException(status_code=400, detail=f"invalid prefix {prefix!r}")
    try:
        removed = await store_delete_plan(session, prefix, name)
    except PlanError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    if removed == 0:
        raise HTTPException(status_code=404, detail=f"no stored plan {prefix}/{name}")
    await session.commit()
    return {"prefix": prefix, "name": name, "deleted_versions": removed}


@router.post("/api/v1/plans/stored/{prefix}/{name}/move")
async def move_plan(
    prefix: str,
    name: str,
    body: MovePlanRequest,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Place a plan/role into a folder path (creates the folder implicitly)."""
    if prefix not in VALID_PREFIXES:
        raise HTTPException(status_code=400, detail=f"invalid prefix {prefix!r}")
    row = await plan_library.set_placement(session, prefix, name, body.folder)
    await session.commit()
    return {"prefix": prefix, "name": name, "folder": row.folder}


@router.get("/api/v1/plans/stored/{prefix}/{name}/versions")
async def plan_versions(
    prefix: str,
    name: str,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Every stored version of a plan (newest first) for the diff/version picker."""
    if prefix not in VALID_PREFIXES:
        raise HTTPException(status_code=400, detail=f"invalid prefix {prefix!r}")
    rows = (await session.scalars(
        select(PlanDocument)
        .where(PlanDocument.prefix == prefix, PlanDocument.name == name)
        .order_by(PlanDocument.version.desc())
    )).all()
    return {"versions": [
        {"version": r.version, "source_format": r.source_format, "content_hash": r.content_hash,
         "created_at": r.created_at.isoformat() if r.created_at else None, "created_by": r.created_by}
        for r in rows
    ]}


@router.get("/api/v1/plans/stored/{prefix}/{name}/document")
async def plan_document(
    prefix: str,
    name: str,
    version: int | None = None,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """A stored plan version rendered in ALL THREE authoring formats (NestedText
    / YAML / JSON) from the one canonical JSON body, so the editor's format
    toggle is instant. Defaults to the latest version; `version` selects an
    older one (for diffing). Also returns source_text + source_format + folder."""
    if prefix not in VALID_PREFIXES:
        raise HTTPException(status_code=400, detail=f"invalid prefix {prefix!r}")
    q = select(PlanDocument).where(PlanDocument.prefix == prefix, PlanDocument.name == name)
    if version is not None:
        q = q.where(PlanDocument.version == version)
    doc = await session.scalar(q.order_by(PlanDocument.version.desc()))
    if doc is None:
        raise HTTPException(status_code=404, detail=f"no stored plan {prefix}/{name}")
    folders = await plan_library.placement_map(session)
    try:
        nt = doc_to_nt(doc.body)
    except Exception:  # noqa: BLE001 — never let one renderer break the view
        nt = ""
    try:
        yml = doc_to_yaml(doc.body)
    except Exception:  # noqa: BLE001
        yml = ""
    return {
        "prefix": prefix,
        "name": name,
        "version": doc.version,
        "source_format": doc.source_format,
        "folder": folders.get((prefix, name), ""),
        "formats": {"nt": nt, "yaml": yml, "json": json.dumps(doc.body, indent=2, ensure_ascii=False)},
        "source_text": doc.source_text,
    }


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
    if not await user_can_manage_agent(session, identity, agent.id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
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
