"""Docker app target endpoints (app-system increment 2) — deploy/list/remove a
container from values on one host. See services/docker_app.py."""
from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import require_manage_agent
from bossman.api.management import _agent_with_address
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services.docker_app import deploy_container, inspect_containers, list_containers, remove_container

router = APIRouter()


class DockerDeployBody(BaseModel):
    name: str
    image: str
    ports: list[dict[str, Any]] = []       # [{host, container}]
    env: dict[str, Any] = {}
    volumes: list[str] = []
    restart: str = "unless-stopped"
    dry_run: bool = False


class DockerRemoveBody(BaseModel):
    name: str


@router.post("/api/v1/agents/{agent_id}/docker/deploy")
async def docker_deploy(
    agent_id: UUID,
    body: DockerDeployBody,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Deploy (idempotently replace) a container from values. dry_run shows the
    command without running it."""
    agent = await _agent_with_address(session, agent_id)
    return await deploy_container(
        agent, client_factory, settings,
        name=body.name, image=body.image, ports=body.ports, env=body.env,
        volumes=body.volumes, restart=body.restart, dry_run=body.dry_run,
    )


@router.get("/api/v1/agents/{agent_id}/docker/containers")
async def docker_list(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Containers on the host (docker ps -a)."""
    agent = await _agent_with_address(session, agent_id)
    return await list_containers(agent, client_factory, settings)


@router.get("/api/v1/agents/{agent_id}/docker/inspect")
async def docker_inspect(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Recover every container as a portable spec (docker inspect) incl. its
    docker-compose file — the observe side of the docker tier (desired state)."""
    agent = await _agent_with_address(session, agent_id)
    return await inspect_containers(agent, client_factory, settings)


@router.post("/api/v1/agents/{agent_id}/docker/remove")
async def docker_remove(
    agent_id: UUID,
    body: DockerRemoveBody,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Force-remove a container by name."""
    agent = await _agent_with_address(session, agent_id)
    return await remove_container(agent, client_factory, settings, name=body.name)
