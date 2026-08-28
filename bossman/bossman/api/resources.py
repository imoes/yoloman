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

from bossman.api.auth import get_current_identity, require_manage_agent
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


@router.get("/api/v1/resource-kinds")
async def resource_kinds(_identity=Depends(get_current_identity)) -> dict[str, Any]:
    """What kinds exist and how each one behaves — the registry as plain data.

    The UI used to hard-code this and got it wrong: it built a `/schema` URL for every
    kind including `config`, which has no such endpoint (docs/logik-audit.md area 7).
    Deriving the capabilities from here means the client cannot disagree with the
    server about what a kind can do — there is one source of truth, and it is the one
    the routes themselves use.
    """
    return {"kinds": resources.as_dict()}


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
    """What would change about this container, without touching it.

    Returns the diff between the container as it runs now and the spec in the body:
    image, published ports, environment, volumes, restart policy. Nothing is written,
    so this is safe to call on anything at any time — and it is the call to make
    before `apply`, because a plan is reviewable and an apply is not.
    """
    r = await _docker_resource(agent_id, name, session, settings, client_factory)
    return await r.plan(body.model_dump())


@router.post("/api/v1/agents/{agent_id}/resources/docker/{name}/apply")
async def docker_apply(
    agent_id: UUID, name: str, body: ApplyBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Bring the container to the spec in the body — and note the default.

    **`dry_run` defaults to `true`.** A caller that omits it gets the plan and no
    change, which is the safe direction for a default to fail in, but it also means a
    naive "apply" reports success while having done nothing. Send `dry_run: false`
    when you mean it.

    A successful non-dry apply records a **generation**: the spec that was applied,
    with the optional `note`. That is what `rollback` reverts to and what
    `GET .../generations` lists — the container is recreated from the spec rather than
    patched, so anything not in the spec is not preserved.
    """
    r = await _docker_resource(agent_id, name, session, settings, client_factory)
    spec = body.model_dump(exclude={"dry_run", "note"})
    return await r.apply(spec, dry_run=body.dry_run, note=body.note)


@router.post("/api/v1/agents/{agent_id}/resources/docker/{name}/rollback")
async def docker_rollback(
    agent_id: UUID, name: str, body: RollbackBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Recreate the container from an earlier generation's spec.

    `generation` is a number from `GET .../generations`. This is a real revert, not a
    forward-converge: the stored spec is applied as it was. What it cannot restore is
    anything that was never part of the spec — data in an anonymous volume, or a
    manual `docker exec` change — because a generation records the declaration, not
    the container's contents.
    """
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
    """What this release would become: the chart and values in the body against the
    release as installed. Reads only. `namespace` defaults to `default`."""
    r = await _helm_resource(agent_id, name, namespace, session, settings, client_factory)
    return await r.plan(body.model_dump())


@router.post("/api/v1/agents/{agent_id}/resources/helm/{name}/apply")
async def helm_apply(
    agent_id: UUID, name: str, body: HelmApplyBody, namespace: str = Query("default"),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Install or upgrade the release to the chart and values in the body.

    **`dry_run` defaults to `true`** here too — see `docker_apply` for why that
    matters. A non-dry apply records a generation (chart + values + note), which is
    what `rollback` targets. Helm keeps its own revision history as well; the
    generation recorded here is Bossman's, and the two are not the same numbering.
    """
    r = await _helm_resource(agent_id, name, namespace, session, settings, client_factory)
    return await r.apply(body.model_dump(exclude={"dry_run", "note"}), dry_run=body.dry_run, note=body.note)


@router.post("/api/v1/agents/{agent_id}/resources/helm/{name}/rollback")
async def helm_rollback(
    agent_id: UUID, name: str, body: RollbackBody, namespace: str = Query("default"),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Re-apply an earlier generation's chart and values. `generation` comes from
    `GET .../generations` — it is Bossman's number, not Helm's revision."""
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
    """What would change in this configuration file, key by key.

    The file is addressed by `path` in the query string, not by a name segment — a
    filesystem path cannot ride in a URL segment unescaped. The body's `values` are
    the keys you want to declare; the plan shows them against what the host's file
    holds now.

    Which of the two write paths applies is decided by the file's **codec**, not by
    the caller: a file this system can parse is written by merge, one it cannot is
    written by whole-file render from a template. Ask
    `GET /api/v1/config-fields?path=…` to find out which, along with the fields this
    file actually has.
    """
    r = await _config_resource(agent_id, path, session, settings, client_factory)
    return await r.plan(body.model_dump())


@router.post("/api/v1/agents/{agent_id}/resources/config/apply")
async def config_apply(
    agent_id: UUID, body: ConfigApplyBody, path: str = Query(...),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Write the declared keys to the file — by merge, so foreign keys survive.

    **`dry_run` defaults to `true`.** With `dry_run: false`, the agent parses the
    file, overlays exactly the keys in `values`, and serialises it back: keys nobody
    declared are left as they were, including comments where the codec preserves
    them. That is the whole point of the merge path — a whole-file render would
    silently destroy anything it did not know about.

    A key set to `null` is *removed* rather than written empty, which is a different
    statement about the file and is why the value model allows it.
    """
    r = await _config_resource(agent_id, path, session, settings, client_factory)
    return await r.apply(body.model_dump(exclude={"dry_run"}), dry_run=body.dry_run)


@router.post("/api/v1/agents/{agent_id}/resources/config/rollback")
async def config_rollback(
    agent_id: UUID, body: RollbackBody, path: str = Query(...),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Restore this file to an earlier generation of declared values.

    `generation` comes from `GET .../generations?path=…`. What is restored is the
    declaration, then re-merged — so keys the host gained from elsewhere in the
    meantime are still not touched.

    Two limits worth knowing. Generations here are kept **without any retention
    limit**: nothing prunes `resource_generations`, so the table grows with every
    apply. (There *is* a 30-generation cap in this system, but it belongs to the
    separate docker desired-state model — `services/docker_desired.py`, pruned on
    discover — and it does not apply to this table. Do not assume one from the
    other.) And this endpoint always merges; the `exact`
    write mode the underlying `config` module offers (file holds exactly these keys,
    nothing else) is not reachable here, deliberately, because a resource whose
    rollback could delete undeclared keys would not be safe to roll back.
    """
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
    """Bind this role to the host — desired state, not an immediate run.

    A role is an OrchestrationPlan of type `role`; binding it means the host is
    *supposed* to have it, and the binding converges when the host next checks in.
    That is why this works on a host with no address at all, including a bare-metal
    machine that has not booted yet: the binding is database state.

    Two defaults to know. **`dry_run` defaults to `true`**, so an apply that omits it
    changes nothing. And **`require_approval` defaults to `true`**: the binding is
    created `pending_approval` and does nothing until someone approves it, unless
    approval is waived here or global YOLO mode is on. The gate is deliberate — see
    the remediation guardrails for the same pattern.
    """
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
    """What installing, removing or upgrading this package would do on this host.

    `state` is `present`, `absent` or `latest`. `latest` is not idempotent in the way
    the other two are — it means "whatever the repository currently offers", so it
    can change on a host that nobody touched, and a plan for it is only true for as
    long as the repository stays put.
    """
    r = _pkg_resource(await _agent_with_address(session, agent_id), session, settings, client_factory, name)
    return await r.plan(body.model_dump())


@router.post("/api/v1/agents/{agent_id}/resources/package/{name}/apply")
async def package_apply(agent_id: UUID, name: str, body: PackageApplyBody, session: AsyncSession = Depends(get_session),
                        settings: Settings = Depends(get_settings), _i=Depends(require_manage_agent),
                        client_factory=Depends(get_client_factory)) -> dict[str, Any]:
    """Install, remove or upgrade the package. **`dry_run` defaults to `true`.**

    Reaches the host's own package manager through the `package` module, so it is
    idempotent for `present` and `absent`: applying twice equals applying once, and
    the response says `changed: false` when nothing had to happen. A generation is
    recorded so `rollback` can restore the previous declared state — that restores
    the *declaration* (`present`/`absent`/version), not the exact binary contents of
    a repository that has moved on.
    """
    r = _pkg_resource(await _agent_with_address(session, agent_id), session, settings, client_factory, name)
    return await r.apply(body.model_dump(exclude={"dry_run", "note"}), dry_run=body.dry_run, note=body.note)


@router.post("/api/v1/agents/{agent_id}/resources/package/{name}/rollback")
async def package_rollback(agent_id: UUID, name: str, body: RollbackBody, session: AsyncSession = Depends(get_session),
                           settings: Settings = Depends(get_settings), _i=Depends(require_manage_agent),
                           client_factory=Depends(get_client_factory)) -> dict[str, Any]:
    """Re-apply this package's previous declared state from `GET .../generations`.
    Restores the declaration, not a snapshot: if the repository now offers a
    different version, `present` will install that one."""
    r = _pkg_resource(await _agent_with_address(session, agent_id), session, settings, client_factory, name)
    return await r.rollback(body.generation)


@router.post("/api/v1/agents/{agent_id}/resources/service/{name}/plan")
async def service_plan(agent_id: UUID, name: str, body: ServiceSpec, session: AsyncSession = Depends(get_session),
                       settings: Settings = Depends(get_settings), _i=Depends(require_manage_agent),
                       client_factory=Depends(get_client_factory)) -> dict[str, Any]:
    """What would change about this service unit: whether it is enabled at boot
    (`enabled`) and whether it is running (`state`: started, stopped, restarted,
    reloaded). Only the fields you send are considered — the two are independent, and
    a plan that assumed the missing one would be inventing a declaration."""
    r = _svc_resource(await _agent_with_address(session, agent_id), session, settings, client_factory, name)
    return await r.plan(body.model_dump(exclude_none=True))


@router.post("/api/v1/agents/{agent_id}/resources/service/{name}/apply")
async def service_apply(agent_id: UUID, name: str, body: ServiceApplyBody, session: AsyncSession = Depends(get_session),
                        settings: Settings = Depends(get_settings), _i=Depends(require_manage_agent),
                        client_factory=Depends(get_client_factory)) -> dict[str, Any]:
    """Set the service's boot-enablement and/or run state. **`dry_run` defaults to
    `true`.**

    `enabled` and `state` are separate declarations and either may be omitted: a unit
    can legitimately be enabled and stopped, or running and disabled, and this
    endpoint will not quietly make them agree. Note that `restarted` and `reloaded`
    are *actions*, not states — they are never idempotent, and the response reports
    `changed: true` every time because that is what happened.
    """
    r = _svc_resource(await _agent_with_address(session, agent_id), session, settings, client_factory, name)
    return await r.apply(body.model_dump(exclude={"dry_run", "note"}, exclude_none=True), dry_run=body.dry_run, note=body.note)


@router.post("/api/v1/agents/{agent_id}/resources/service/{name}/rollback")
async def service_rollback(agent_id: UUID, name: str, body: RollbackBody, session: AsyncSession = Depends(get_session),
                           settings: Settings = Depends(get_settings), _i=Depends(require_manage_agent),
                           client_factory=Depends(get_client_factory)) -> dict[str, Any]:
    """Re-apply this unit's previous declared enablement and run state from
    `GET .../generations`. A rollback of `restarted` re-runs the restart, since there
    is no earlier state to return to — the response says so."""
    r = _svc_resource(await _agent_with_address(session, agent_id), session, settings, client_factory, name)
    return await r.rollback(body.generation)
