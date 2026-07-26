"""Resource / Deployable endpoints (docs/resource-protocol.md) — the four-verb
contract over HTTP, first implementation: the docker_container tier with its own
generations + rollback. observe / plan / apply / generations / rollback, plus
schema (for a form / canvas node)."""
from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import require_manage_agent
from bossman.api.management import _agent_with_address
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services.resources.config_file import ConfigResource
from bossman.services.resources.docker_container import DockerContainerResource
from bossman.services.resources.helm_release import HelmReleaseResource
from bossman.services.resources.role import RoleResource

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


# --- Config file tier (delegates to the agent state store) ----------------

class ConfigSpec(BaseModel):
    values: dict[str, Any] = {}
    format: str | None = None
    separator: str | None = None


class ConfigApplyBody(ConfigSpec):
    dry_run: bool = True


async def _config_resource(agent_id: UUID, path: str, session, settings, client_factory) -> ConfigResource:
    agent = await _agent_with_address(session, agent_id)
    return ConfigResource(session, agent, client_factory, settings, path)


@router.get("/api/v1/agents/{agent_id}/resources/config/observe")
async def config_observe(
    agent_id: UUID, path: str = Query(...),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _config_resource(agent_id, path, session, settings, client_factory)
    return {"resource_key": r.resource_key, "observed": await r.observe(), "schema": r.schema()}


@router.post("/api/v1/agents/{agent_id}/resources/config/plan")
async def config_plan(
    agent_id: UUID, body: ConfigSpec, path: str = Query(...),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _config_resource(agent_id, path, session, settings, client_factory)
    return await r.plan(body.model_dump())


@router.post("/api/v1/agents/{agent_id}/resources/config/apply")
async def config_apply(
    agent_id: UUID, body: ConfigApplyBody, path: str = Query(...),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _config_resource(agent_id, path, session, settings, client_factory)
    return await r.apply(body.model_dump(exclude={"dry_run"}), dry_run=body.dry_run)


@router.get("/api/v1/agents/{agent_id}/resources/config/generations")
async def config_generations(
    agent_id: UUID, path: str = Query(...),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _config_resource(agent_id, path, session, settings, client_factory)
    return {"resource_key": r.resource_key, "scope": "host", "generations": await r.generations()}


@router.post("/api/v1/agents/{agent_id}/resources/config/rollback")
async def config_rollback(
    agent_id: UUID, body: RollbackBody, path: str = Query(...),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _config_resource(agent_id, path, session, settings, client_factory)
    return await r.rollback(body.generation)


# --- Role tier (a runbook Role: parameters = constructor, apply = run) -----

class RoleSpec(BaseModel):
    parameters: dict[str, Any] = {}


class RoleApplyBody(RoleSpec):
    dry_run: bool = True
    note: str | None = None


async def _role_resource(agent_id: UUID, name: str, session, settings, client_factory, identity) -> RoleResource:
    agent = await _agent_with_address(session, agent_id)
    r = RoleResource(session, agent, client_factory, settings, name,
                     requested_by=getattr(identity, "name", "resource-api"))
    if await r._role_doc() is None:   # 404 instead of a 500 deeper in the engine
        raise HTTPException(status_code=404, detail=f"no such role: {name!r}")
    return r


@router.get("/api/v1/agents/{agent_id}/resources/role/{name}/schema")
async def role_schema(
    agent_id: UUID, name: str,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _role_resource(agent_id, name, session, settings, client_factory, identity)
    return {"resource_key": r.resource_key, "type": r.resource_type, "schema": await r.schema_async()}


@router.get("/api/v1/agents/{agent_id}/resources/role/{name}/observe")
async def role_observe(
    agent_id: UUID, name: str,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _role_resource(agent_id, name, session, settings, client_factory, identity)
    return {"resource_key": r.resource_key, "observed": await r.observe(), "schema": await r.schema_async()}


@router.post("/api/v1/agents/{agent_id}/resources/role/{name}/plan")
async def role_plan(
    agent_id: UUID, name: str, body: RoleSpec,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Check-mode run: the steps that WOULD change (no writes)."""
    r = await _role_resource(agent_id, name, session, settings, client_factory, identity)
    return await r.plan(body.model_dump())


@router.post("/api/v1/agents/{agent_id}/resources/role/{name}/apply")
async def role_apply(
    agent_id: UUID, name: str, body: RoleApplyBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    r = await _role_resource(agent_id, name, session, settings, client_factory, identity)
    return await r.apply(body.model_dump(exclude={"dry_run", "note"}), dry_run=body.dry_run, note=body.note)


@router.get("/api/v1/agents/{agent_id}/resources/role/{name}/generations")
async def role_generations(
    agent_id: UUID, name: str,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Applied parameter sets (rollback points). Per-step execution audit is in Runs."""
    r = await _role_resource(agent_id, name, session, settings, client_factory, identity)
    return {"resource_key": r.resource_key, "generations": await r.generations()}


@router.post("/api/v1/agents/{agent_id}/resources/role/{name}/rollback")
async def role_rollback(
    agent_id: UUID, name: str, body: RollbackBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Re-run the role with an earlier parameter set (forward-converge; only truly
    reverts if the role's steps are idempotent — the response says so)."""
    r = await _role_resource(agent_id, name, session, settings, client_factory, identity)
    return await r.rollback(body.generation)
