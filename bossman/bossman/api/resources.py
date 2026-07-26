"""Resource / Deployable endpoints (docs/resource-protocol.md) — the four-verb
contract over HTTP, first implementation: the docker_container tier with its own
generations + rollback. observe / plan / apply / generations / rollback, plus
schema (for a form / canvas node)."""
from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import require_manage_agent
from bossman.api.management import _agent_with_address
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services.resources.docker_container import DockerContainerResource
from bossman.services.resources.helm_release import HelmReleaseResource

router = APIRouter()


class DockerSpec(BaseModel):
    image: str = ""
    ports: list[dict[str, Any]] = []       # [{host, container}]
    env: dict[str, Any] = {}
    volumes: list[str] = []
    restart: str = "unless-stopped"


class ApplyBody(DockerSpec):
    dry_run: bool = True
    note: str | None = None


class RollbackBody(BaseModel):
    generation: int


async def _docker_resource(agent_id: UUID, name: str, session, settings, client_factory) -> DockerContainerResource:
    agent = await _agent_with_address(session, agent_id)
    return DockerContainerResource(session, agent, client_factory, settings, name)


@router.get("/api/v1/agents/{agent_id}/resources/docker/{name}/schema")
async def docker_schema(
    agent_id: UUID, name: str,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _docker_resource(agent_id, name, session, settings, client_factory)
    return {"resource_key": r.resource_key, "type": r.resource_type, "schema": r.schema()}


@router.get("/api/v1/agents/{agent_id}/resources/docker/{name}/observe")
async def docker_observe(
    agent_id: UUID, name: str,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _docker_resource(agent_id, name, session, settings, client_factory)
    return {"resource_key": r.resource_key, "observed": await r.observe()}


@router.post("/api/v1/agents/{agent_id}/resources/docker/{name}/plan")
async def docker_plan(
    agent_id: UUID, name: str, body: DockerSpec,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _docker_resource(agent_id, name, session, settings, client_factory)
    return await r.plan(body.model_dump())


@router.post("/api/v1/agents/{agent_id}/resources/docker/{name}/apply")
async def docker_apply(
    agent_id: UUID, name: str, body: ApplyBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _docker_resource(agent_id, name, session, settings, client_factory)
    spec = body.model_dump(exclude={"dry_run", "note"})
    return await r.apply(spec, dry_run=body.dry_run, note=body.note)


@router.get("/api/v1/agents/{agent_id}/resources/docker/{name}/generations")
async def docker_generations(
    agent_id: UUID, name: str,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _docker_resource(agent_id, name, session, settings, client_factory)
    return {"resource_key": r.resource_key, "generations": await r.generations()}


@router.post("/api/v1/agents/{agent_id}/resources/docker/{name}/rollback")
async def docker_rollback(
    agent_id: UUID, name: str, body: RollbackBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _docker_resource(agent_id, name, session, settings, client_factory)
    return await r.rollback(body.generation)


# --- Helm release tier (same four-verb contract) --------------------------

class HelmSpec(BaseModel):
    chart: str = ""
    values: dict[str, Any] = {}


class HelmApplyBody(HelmSpec):
    dry_run: bool = True
    note: str | None = None


async def _helm_resource(agent_id: UUID, name: str, namespace: str, session, settings, client_factory) -> HelmReleaseResource:
    agent = await _agent_with_address(session, agent_id)
    return HelmReleaseResource(session, agent, client_factory, settings, name, namespace=namespace or "default")


@router.get("/api/v1/agents/{agent_id}/resources/helm/{name}/schema")
async def helm_schema(
    agent_id: UUID, name: str, namespace: str = Query("default"),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _helm_resource(agent_id, name, namespace, session, settings, client_factory)
    return {"resource_key": r.resource_key, "type": r.resource_type, "schema": r.schema()}


@router.get("/api/v1/agents/{agent_id}/resources/helm/{name}/observe")
async def helm_observe(
    agent_id: UUID, name: str, namespace: str = Query("default"),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _helm_resource(agent_id, name, namespace, session, settings, client_factory)
    return {"resource_key": r.resource_key, "observed": await r.observe()}


@router.post("/api/v1/agents/{agent_id}/resources/helm/{name}/plan")
async def helm_plan(
    agent_id: UUID, name: str, body: HelmSpec, namespace: str = Query("default"),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _helm_resource(agent_id, name, namespace, session, settings, client_factory)
    return await r.plan(body.model_dump())


@router.post("/api/v1/agents/{agent_id}/resources/helm/{name}/apply")
async def helm_apply(
    agent_id: UUID, name: str, body: HelmApplyBody, namespace: str = Query("default"),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _helm_resource(agent_id, name, namespace, session, settings, client_factory)
    return await r.apply(body.model_dump(exclude={"dry_run", "note"}), dry_run=body.dry_run, note=body.note)


@router.get("/api/v1/agents/{agent_id}/resources/helm/{name}/generations")
async def helm_generations(
    agent_id: UUID, name: str, namespace: str = Query("default"),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _helm_resource(agent_id, name, namespace, session, settings, client_factory)
    return {"resource_key": r.resource_key, "generations": await r.generations()}


@router.post("/api/v1/agents/{agent_id}/resources/helm/{name}/rollback")
async def helm_rollback(
    agent_id: UUID, name: str, body: RollbackBody, namespace: str = Query("default"),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _helm_resource(agent_id, name, namespace, session, settings, client_factory)
    return await r.rollback(body.generation)
