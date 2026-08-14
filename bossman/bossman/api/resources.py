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
from bossman.db.models import Agent
from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services import resources
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



async def _read(kind: str, verb: str, **kw) -> dict[str, Any]:
    """Build the resource and run a read verb, translating the service's own errors
    into HTTP. The service raises LookupError/RuntimeError subclasses and never knows
    about HTTP; this is the one place that maps them — and it passes the message
    through, so a refusal keeps naming its reason."""
    try:
        resource = await resources.build(kind, **kw)
        return await resources.read_verb(kind, verb, resource)
    except resources.NoSuchResource as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from None
    except resources.ResourceUnreachable as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from None
    except ValueError as exc:                     # unknown kind / not a read verb
        raise HTTPException(status_code=400, detail=str(exc)) from None


@router.get("/api/v1/agents/{agent_id}/resources/{kind}/{name}/{verb}")
async def resource_read(
    agent_id: UUID, kind: str, name: str, verb: str,
    namespace: str = Query("default"),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """The READ half of the four-verb contract, for every kind — `schema`, `observe`
    and `generations`.

    This used to be seventeen near-identical routes (six kinds x three verbs, minus
    config's missing schema). The paths are unchanged; what changed is that the
    per-kind differences now come from `services/resources`' registry instead of from
    copies: which schema method a kind has, whether it needs a reachable host, whether
    its observe carries a schema, whether its history has a scope. See
    docs/logik-audit.md area 7 for why the duplication was the actual defect.

    `config` is addressed by a filesystem path rather than a name segment, so it has
    its own route below.
    """
    if verb not in resources.READ_VERBS:
        raise HTTPException(status_code=400, detail=(
            f"{verb!r} is not a read verb — expected one of: {', '.join(resources.READ_VERBS)}"))
    return await _read(kind, verb, agent_id=agent_id, name=name, session=session,
                       settings=settings, client_factory=client_factory, identity=identity,
                       namespace=namespace)


@router.get("/api/v1/agents/{agent_id}/resources/config/{verb}")
async def config_read(
    agent_id: UUID, verb: str, path: str = Query(...),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """`config`'s read verbs. Separate only because its instance is a filesystem path,
    which cannot ride in a URL segment unescaped — the reason is declared as
    `addressed_by='path'` in the registry rather than implied by this route existing."""
    if verb not in resources.READ_VERBS:
        raise HTTPException(status_code=400, detail=(
            f"{verb!r} is not a read verb — expected one of: {', '.join(resources.READ_VERBS)}"))
    return await _read("config", verb, agent_id=agent_id, name=path, session=session,
                       settings=settings, client_factory=client_factory, identity=identity)


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
    # A binding starts `pending_approval` unless approval is waived here or global
    # YOLO mode is on — the governance gate, not something this tier bypasses.
    require_approval: bool = True


async def _role_resource(agent_id: UUID, name: str, session, settings, client_factory, identity) -> RoleResource:
    # A role binding is DB-only desired state (OrchestrationPlanLink) — RoleResource never dials the agent,
    # so unlike config/service resources it must NOT require an address. That lets a PLANNED (bare-metal,
    # not-yet-booted) host be given roles now; the binding converges when the host first checks in.
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="no such agent")
    r = RoleResource(session, agent, client_factory, settings, name,
                     requested_by=getattr(identity, "name", "resource-api"))
    if await r._plan_row() is None:   # 404 rather than failing deeper down
        raise HTTPException(
            status_code=404,
            detail=f"no such role: {name!r} — a role is an OrchestrationPlan of type 'role' "
                   f"(author it in Ansible task syntax under a `role:` key and compile via POST /api/v1/runbooks/role/compile)")
    return r


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


@router.delete("/api/v1/agents/{agent_id}/resources/role/{name}/binding")
async def role_unbind(
    agent_id: UUID, name: str,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Remove this host's direct binding of the role (the counterpart of apply) and
    recompile the host's desired state. Inherited bindings (OU/group) are untouched
    — unbind those at their own scope."""
    r = await _role_resource(agent_id, name, session, settings, client_factory, identity)
    return await r.unbind()


# --- Package + Service tiers (same four-verb contract) --------------------
# New generic Resource kinds with no bespoke tab of their own — managed entirely
# in the host Resources inspector. Adding a kind is exactly this: an adapter
# (services/resources/*) + these six routes.

from bossman.services.resources.package_resource import PackageResource  # noqa: E402
from bossman.services.resources.service_resource import ServiceResource  # noqa: E402


class PackageSpec(BaseModel):
    state: str = "present"  # present | absent | latest


class PackageApplyBody(PackageSpec):
    dry_run: bool = True
    note: str | None = None


class ServiceSpec(BaseModel):
    enabled: bool | None = None
    state: str | None = None  # started | stopped | restarted | reloaded


class ServiceApplyBody(ServiceSpec):
    dry_run: bool = True
    note: str | None = None


def _pkg_resource(agent, session, settings, client_factory, name: str) -> PackageResource:
    return PackageResource(session, agent, client_factory, settings, name)


def _svc_resource(agent, session, settings, client_factory, name: str) -> ServiceResource:
    return ServiceResource(session, agent, client_factory, settings, name)


@router.post("/api/v1/agents/{agent_id}/resources/package/{name}/plan")
async def package_plan(agent_id: UUID, name: str, body: PackageSpec, session: AsyncSession = Depends(get_session),
                       settings: Settings = Depends(get_settings), _i=Depends(require_manage_agent),
                       client_factory=Depends(get_client_factory)) -> dict[str, Any]:
    r = _pkg_resource(await _agent_with_address(session, agent_id), session, settings, client_factory, name)
    return await r.plan(body.model_dump())


@router.post("/api/v1/agents/{agent_id}/resources/package/{name}/apply")
async def package_apply(agent_id: UUID, name: str, body: PackageApplyBody, session: AsyncSession = Depends(get_session),
                        settings: Settings = Depends(get_settings), _i=Depends(require_manage_agent),
                        client_factory=Depends(get_client_factory)) -> dict[str, Any]:
    r = _pkg_resource(await _agent_with_address(session, agent_id), session, settings, client_factory, name)
    return await r.apply(body.model_dump(exclude={"dry_run", "note"}), dry_run=body.dry_run, note=body.note)


@router.post("/api/v1/agents/{agent_id}/resources/package/{name}/rollback")
async def package_rollback(agent_id: UUID, name: str, body: RollbackBody, session: AsyncSession = Depends(get_session),
                           settings: Settings = Depends(get_settings), _i=Depends(require_manage_agent),
                           client_factory=Depends(get_client_factory)) -> dict[str, Any]:
    r = _pkg_resource(await _agent_with_address(session, agent_id), session, settings, client_factory, name)
    return await r.rollback(body.generation)


@router.post("/api/v1/agents/{agent_id}/resources/service/{name}/plan")
async def service_plan(agent_id: UUID, name: str, body: ServiceSpec, session: AsyncSession = Depends(get_session),
                       settings: Settings = Depends(get_settings), _i=Depends(require_manage_agent),
                       client_factory=Depends(get_client_factory)) -> dict[str, Any]:
    r = _svc_resource(await _agent_with_address(session, agent_id), session, settings, client_factory, name)
    return await r.plan(body.model_dump(exclude_none=True))


@router.post("/api/v1/agents/{agent_id}/resources/service/{name}/apply")
async def service_apply(agent_id: UUID, name: str, body: ServiceApplyBody, session: AsyncSession = Depends(get_session),
                        settings: Settings = Depends(get_settings), _i=Depends(require_manage_agent),
                        client_factory=Depends(get_client_factory)) -> dict[str, Any]:
    r = _svc_resource(await _agent_with_address(session, agent_id), session, settings, client_factory, name)
    return await r.apply(body.model_dump(exclude={"dry_run", "note"}, exclude_none=True), dry_run=body.dry_run, note=body.note)


@router.post("/api/v1/agents/{agent_id}/resources/service/{name}/rollback")
async def service_rollback(agent_id: UUID, name: str, body: RollbackBody, session: AsyncSession = Depends(get_session),
                           settings: Settings = Depends(get_settings), _i=Depends(require_manage_agent),
                           client_factory=Depends(get_client_factory)) -> dict[str, Any]:
    r = _svc_resource(await _agent_with_address(session, agent_id), session, settings, client_factory, name)
    return await r.rollback(body.generation)
