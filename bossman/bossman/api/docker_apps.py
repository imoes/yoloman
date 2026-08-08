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


# --- Docker app-store templates (README-extracted variables) ---
from fastapi import HTTPException, Query  # noqa: E402
from sqlalchemy import select  # noqa: E402

from bossman.api.auth import get_current_identity  # noqa: E402
from bossman.db.models import DockerAppTemplate  # noqa: E402


class DockerAppTemplateOut(BaseModel):
    image: str
    name: str
    description: str
    variables: list
    ports: list
    volumes: list
    popularity: int


@router.get("/api/v1/docker/app-templates", response_model=list[DockerAppTemplateOut])
async def list_docker_app_templates(
    session: AsyncSession = Depends(get_session), _i=Depends(get_current_identity)
):
    """The docker app-store catalog: containers with their README-extracted
    variables (env → params), ports and volumes, most-popular first."""
    rows = (await session.scalars(
        select(DockerAppTemplate).order_by(DockerAppTemplate.popularity.desc(), DockerAppTemplate.image)
    )).all()
    return [DockerAppTemplateOut(
        image=r.image, name=r.name, description=r.description, variables=r.variables or [],
        ports=r.ports or [], volumes=r.volumes or [], popularity=r.popularity,
    ) for r in rows]


class DockerExtractBody(BaseModel):
    image: str


@router.post("/api/v1/docker/app-templates/extract", response_model=DockerAppTemplateOut)
async def extract_docker_app_template(
    body: DockerExtractBody, session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings), _i=Depends(get_current_identity),
):
    """Extract one image's configurable variables from its Docker Hub README
    (via the OpenRouter model settings.docker_extract_model) and store it."""
    from bossman.services.docker_readme import extract_and_store

    try:
        row = await extract_and_store(session, settings, body.image.strip())
    except ValueError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    await session.commit()
    return DockerAppTemplateOut(
        image=row.image, name=row.name, description=row.description, variables=row.variables or [],
        ports=row.ports or [], volumes=row.volumes or [], popularity=row.popularity,
    )


@router.post("/api/v1/docker/app-templates/extract-batch")
async def extract_docker_catalog(
    limit: int = Query(100, ge=1, le=200), session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings), _i=Depends(get_current_identity),
):
    """Populate the docker catalog: extract variables for the top `limit` curated
    images (services/docker_readme.TOP_IMAGES). Per-image failures are reported,
    never fatal. Idempotent (an unchanged README skips the LLM)."""
    from bossman.services.docker_readme import TOP_IMAGES, extract_and_store

    done, failed = 0, []
    for rank, image in enumerate(TOP_IMAGES[:limit]):
        try:
            await extract_and_store(session, settings, image, popularity=len(TOP_IMAGES) - rank)
            await session.commit()
            done += 1
        except Exception as exc:  # noqa: BLE001 — one bad image must not stop the batch
            await session.rollback()
            failed.append({"image": image, "error": str(exc)[:200]})
    return {"extracted": done, "failed": failed}


# ── Docker desired state: versioned generations + diff + rollback ─────────────
# (project-docker-desired-state) — discover containers into a versioned desired
# state, diff any two generations, and roll back. See services/docker_desired.

from bossman.api.auth import get_current_identity as _get_identity  # noqa: E402
from bossman.services import docker_desired as _dd  # noqa: E402


@router.post("/api/v1/agents/{agent_id}/docker-state/discover")
async def docker_state_discover(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Observe the host's containers and snapshot them as a new desired-state
    generation (only if the canonical spec changed since the last one)."""
    agent = await _agent_with_address(session, agent_id)
    return await _dd.discover(session, agent, client_factory, settings,
                              created_by=getattr(identity, "name", None))


@router.get("/api/v1/agents/{agent_id}/docker-state/generations")
async def docker_state_generations(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(_get_identity),
) -> dict[str, Any]:
    """Every stored container desired-state generation, newest first."""
    return {"generations": await _dd.list_generations(session, agent_id)}


@router.get("/api/v1/agents/{agent_id}/docker-state")
async def docker_state_get(
    agent_id: UUID,
    generation: int | None = Query(None),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(_get_identity),
) -> dict[str, Any]:
    """One generation's full spec (the current/newest if `generation` omitted)."""
    r = await _dd.get_generation(session, agent_id, generation)
    if r is None:
        return {"generation": None, "spec": {"containers": []}}
    return r


@router.get("/api/v1/agents/{agent_id}/docker-state/diff")
async def docker_state_diff(
    agent_id: UUID,
    from_gen: int = Query(..., alias="from"),
    to_gen: int = Query(..., alias="to"),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(_get_identity),
) -> dict[str, Any]:
    """Container-level diff (added / removed / changed) between two generations."""
    return await _dd.diff(session, agent_id, from_gen, to_gen)


class RollbackBody(BaseModel):
    generation: int


@router.post("/api/v1/agents/{agent_id}/docker-state/rollback")
async def docker_state_rollback(
    agent_id: UUID,
    body: RollbackBody,
    session: AsyncSession = Depends(get_session),
    identity=Depends(require_manage_agent),
) -> dict[str, Any]:
    """Set an old generation as the new desired state (forward-only, like config)."""
    agent = await _agent_with_address(session, agent_id)
    return await _dd.rollback(session, agent, body.generation, getattr(identity, "name", "?"))


@router.get("/api/v1/agents/{agent_id}/docker-state/converge-plan")
async def docker_state_converge_plan(
    agent_id: UUID,
    generation: int | None = Query(None),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Preview the actions (create/remove/recreate) to make the host match a
    target generation vs. what is live now — the safe pre-apply diff."""
    agent = await _agent_with_address(session, agent_id)
    return await _dd.plan_converge(session, agent, client_factory, settings, generation)
