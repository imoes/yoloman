"""Blueprint management — CRUD over blueprints + compile-to-playbook + seed
sample drafts. See services/blueprint.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity, require_admin
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import (
    DEFAULT_TENANT_ID,
    Agent,
    Blueprint,
    HostGroup,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OrchestrationPlanVersion,
    OUNode,
    ScopeVars,
)
from bossman.services import blueprint_provision
from bossman.db.session import get_session
from bossman.services.blueprint import (
    compile_blueprint,
    open_requirements_for_fleet,
    plausibility as blueprint_plausibility,
    seed_blueprint_drafts,
)
from bossman.services.capabilities import find_providers, roles_providing
from bossman.services.compiler import (
    affected_agent_ids,
    compile_host_desired_state,
    is_yolo_mode,
)
from bossman.services.vault import Vault


async def _resolve_fleet_providers(session: AsyncSession, settings: Settings, services: list) -> dict:
    """For every requirement with no in-blueprint provider, pick the first matching
    fleet host (host_capabilities). Returns {req_key: find_providers-dict} to hand to
    resolve_wiring/compile so a requirement can be satisfied by an existing server."""
    out: dict = {}
    for openreq in open_requirements_for_fleet(settings, services):
        providers = await find_providers(session, settings, openreq["capability"], openreq["backends"])
        if providers:
            out[openreq["req_key"]] = providers[0]
    return out

router = APIRouter()

# The scope kinds a blueprint can be bound to (mirrors orchestration _TARGET_TYPES).
_BIND_TARGETS = ("ou", "site", "group", "host")


class BlueprintIn(BaseModel):
    name: str
    description: str = ""
    status: str = "draft"
    path: str = ""            # folder path in the blueprint tree ("web/wordpress")
    services: list = []


class BlueprintOut(BaseModel):
    id: UUID
    name: str
    description: str
    status: str
    path: str
    services: list
    created_at: datetime
    updated_at: datetime

    @classmethod
    def of(cls, b: Blueprint) -> "BlueprintOut":
        return cls(id=b.id, name=b.name, description=b.description, status=b.status,
                   path=b.path or "", services=b.services or [], created_at=b.created_at, updated_at=b.updated_at)


@router.get("/api/v1/blueprints", response_model=list[BlueprintOut])
async def list_blueprints(session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    rows = (await session.scalars(select(Blueprint).order_by(Blueprint.name))).all()
    return [BlueprintOut.of(b) for b in rows]


@router.get("/api/v1/blueprints/{bp_id}", response_model=BlueprintOut)
async def get_blueprint(bp_id: UUID, session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    b = await session.get(Blueprint, bp_id)
    if b is None:
        raise HTTPException(404, "no such blueprint")
    return BlueprintOut.of(b)


@router.post("/api/v1/blueprints", response_model=BlueprintOut)
async def create_blueprint(body: BlueprintIn, session: AsyncSession = Depends(get_session),
                           identity: Identity = Depends(get_current_identity)):
    b = Blueprint(tenant_id=DEFAULT_TENANT_ID, name=body.name, description=body.description,
                  status=body.status, path=body.path or "", services=body.services or [], created_by=identity.name)
    session.add(b)
    await session.commit()
    await session.refresh(b)
    return BlueprintOut.of(b)


@router.put("/api/v1/blueprints/{bp_id}", response_model=BlueprintOut)
async def update_blueprint(bp_id: UUID, body: BlueprintIn, session: AsyncSession = Depends(get_session),
                           _i: Identity = Depends(get_current_identity)):
    b = await session.get(Blueprint, bp_id)
    if b is None:
        raise HTTPException(404, "no such blueprint")
    b.name, b.description, b.status, b.services = body.name, body.description, body.status, body.services or []
    b.path = body.path or ""
    b.updated_at = datetime.now(b.updated_at.tzinfo) if b.updated_at else datetime.utcnow()
    await session.commit()
    return BlueprintOut.of(b)


@router.delete("/api/v1/blueprints/{bp_id}", status_code=204)
async def delete_blueprint(bp_id: UUID, session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    b = await session.get(Blueprint, bp_id)
    if b is not None:
        await session.delete(b)
        await session.commit()


@router.get("/api/v1/blueprints/{bp_id}/compile")
async def compile_blueprint_route(bp_id: UUID, session: AsyncSession = Depends(get_session),
                                  settings: Settings = Depends(get_settings), _i: Identity = Depends(get_current_identity)):
    """Compile the blueprint into a typed playbook + wiring/order report. Resolves
    requirements against the fleet too, and MASKS secret values in this preview."""
    b = await session.get(Blueprint, bp_id)
    if b is None:
        raise HTTPException(404, "no such blueprint")
    from bossman.api.config_templates import load_template_bodies

    known = set(load_template_bodies(settings))
    fleet = await _resolve_fleet_providers(session, settings, list(b.services or []))
    return compile_blueprint(settings, b, known_templates=known, fleet_providers=fleet, mask_secrets=True)


@router.get("/api/v1/blueprints/{bp_id}/plausibility")
async def blueprint_plausibility_route(bp_id: UUID, session: AsyncSession = Depends(get_session),
                                       settings: Settings = Depends(get_settings), _i: Identity = Depends(get_current_identity)):
    """Design-time validation: does every requirement resolve (in-blueprint or on a
    real fleet host), and is every connection field supplied? Returns
    {ok, problems[], wiring, unresolved, order}."""
    b = await session.get(Blueprint, bp_id)
    if b is None:
        raise HTTPException(404, "no such blueprint")
    services = list(b.services or [])
    fleet = await _resolve_fleet_providers(session, settings, services)
    return blueprint_plausibility(settings, services, fleet_providers=fleet)


@router.get("/api/v1/blueprints/{bp_id}/suggest-providers")
async def blueprint_suggest_providers(bp_id: UUID, session: AsyncSession = Depends(get_session),
                                      settings: Settings = Depends(get_settings), _i: Identity = Depends(get_current_identity)):
    """For each requirement that no in-blueprint service satisfies, propose how to
    fill it: existing fleet hosts that provide it, plus the catalog roles a NEW
    server would need. Drives step 2 of the designer ("find a matching provider")."""
    b = await session.get(Blueprint, bp_id)
    if b is None:
        raise HTTPException(404, "no such blueprint")
    services = list(b.services or [])
    suggestions = []
    for openreq in open_requirements_for_fleet(settings, services):
        hosts = await find_providers(session, settings, openreq["capability"], openreq["backends"])
        roles = roles_providing(settings, openreq["capability"],
                                (openreq["backends"] or [None])[0] if openreq["backends"] else None)
        suggestions.append({
            "req_key": openreq["req_key"], "consumer": openreq["consumer"],
            "capability": openreq["capability"], "backends": openreq["backends"],
            "fleet_hosts": hosts, "candidate_roles": roles,
        })
    return {"suggestions": suggestions}


class ServicesIn(BaseModel):
    """A live draft's services[] (backend shape) — lets the designer validate/find
    providers WITHOUT first persisting the blueprint."""
    services: list = []


@router.post("/api/v1/blueprints/plausibility")
async def plausibility_stateless(body: ServicesIn, session: AsyncSession = Depends(get_session),
                                 settings: Settings = Depends(get_settings), _i: Identity = Depends(get_current_identity)):
    """Validate an in-flight draft (not yet saved): every requirement resolved
    (in-blueprint or a fleet host), every connection field supplied."""
    fleet = await _resolve_fleet_providers(session, settings, body.services)
    return blueprint_plausibility(settings, body.services, fleet_providers=fleet)


@router.post("/api/v1/blueprints/suggest-providers")
async def suggest_providers_stateless(body: ServicesIn, session: AsyncSession = Depends(get_session),
                                      settings: Settings = Depends(get_settings), _i: Identity = Depends(get_current_identity)):
    """For an in-flight draft, per open requirement: matching fleet hosts + candidate
    roles a new server would need. Drives step 2 of the designer live."""
    suggestions = []
    for openreq in open_requirements_for_fleet(settings, body.services):
        hosts = await find_providers(session, settings, openreq["capability"], openreq["backends"])
        roles = roles_providing(settings, openreq["capability"],
                                (openreq["backends"] or [None])[0] if openreq["backends"] else None)
        suggestions.append({
            "req_key": openreq["req_key"], "consumer": openreq["consumer"],
            "capability": openreq["capability"], "backends": openreq["backends"],
            "fleet_hosts": hosts, "candidate_roles": roles,
        })
    return {"suggestions": suggestions}


class ProvisionIn(BaseModel):
    """Provision a database + user on a provider host and store the credential for
    the consumer. Admin creds are used only for this call and never persisted; the
    app password is stored for the consumer as a vault handle.

    password_mode picks where the app password comes from:
      generate — mint a strong random one (default);
      custom   — use `password` supplied here;
      existing — reuse an already-stored secret referenced by
                 existing_scope_type + the matching id + existing_key (its value
                 must be a vault handle; it is decrypted only to run the SQL, and
                 the SAME handle is stored for the consumer)."""
    provider_agent_id: UUID           # reachable host the DB runs on
    exec: str = "local"               # "local" | "docker"
    container: str | None = None      # docker exec target when exec=docker
    backend: str = "mysql"            # mysql | mariadb
    admin_user: str
    admin_password: str
    db_name: str
    db_user: str
    consumer_agent_id: UUID           # host whose host_vars receive the credential
    targets: dict = {}                # {name|user|password: consumer var key}
    password_mode: str = "generate"   # generate | custom | existing
    password: str = ""                # custom mode
    existing_scope_type: str | None = None   # existing mode: host | group | ou
    existing_agent_id: UUID | None = None
    existing_host_group_id: UUID | None = None
    existing_ou_id: UUID | None = None
    existing_key: str | None = None


@router.post("/api/v1/blueprints/provision")
async def provision_credentials(
    body: ProvisionIn, session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings), client_factory=Depends(get_client_factory),
    _identity: Identity = Depends(require_admin),
) -> dict:
    """Out-of-band credential provisioning (step 4 of the designer, secret-safe):
    create the DB+user on the provider via the agent `command` module, then store
    the password for the consumer as a vault handle in its host_vars. No plaintext
    is persisted and no agent module is required."""
    provider = await session.get(Agent, body.provider_agent_id)
    if provider is None:
        raise HTTPException(404, "no such provider host")
    if not provider.address:
        raise HTTPException(409, "provider host has no direct address — cannot reach it to provision")
    consumer = await session.get(Agent, body.consumer_agent_id)
    if consumer is None:
        raise HTTPException(404, "no such consumer host")

    vault = Vault(settings.vault_key, settings.vault_key_path)

    # Resolve the app password per mode. `existing_handle` is set only for the
    # "existing" mode so the consumer keeps the SAME secret reference.
    app_password: str | None = None
    existing_handle: str | None = None
    if body.password_mode == "custom":
        if not body.password:
            raise HTTPException(422, "custom password mode needs a `password`")
        app_password = body.password
    elif body.password_mode == "existing":
        if not (body.existing_scope_type and body.existing_key):
            raise HTTPException(422, "existing mode needs existing_scope_type + existing_key")
        ref = await session.scalar(select(ScopeVars).where(
            ScopeVars.tenant_id == DEFAULT_TENANT_ID,
            ScopeVars.scope_type == body.existing_scope_type,
            ScopeVars.agent_id == body.existing_agent_id,
            ScopeVars.host_group_id == body.existing_host_group_id,
            ScopeVars.ou_id == body.existing_ou_id))
        handle = (ref.vars if ref else {}).get(body.existing_key) if ref else None
        if not Vault.is_encrypted(handle):
            raise HTTPException(422, "referenced value is not an encrypted secret")
        try:
            app_password = vault.decrypt(handle)
        except Exception:  # noqa: BLE001
            raise HTTPException(422, "could not decrypt the referenced secret")
        existing_handle = handle
    # else: generate → app_password stays None (minted by the recipe)

    client = client_factory(provider, settings)
    res = await blueprint_provision.provision_database(
        client, backend=body.backend, exec_mode=body.exec, container=body.container,
        admin_user=body.admin_user, admin_password=body.admin_password,
        db_name=body.db_name, db_user=body.db_user, app_password=app_password)
    if not res.get("ok"):
        raise HTTPException(502, res.get("error") or "provisioning failed")

    produced = res.get("produced_params") or {}
    pw_handle = existing_handle if existing_handle else vault.encrypt(produced.get("password", ""))
    row = await session.scalar(select(ScopeVars).where(
        ScopeVars.tenant_id == DEFAULT_TENANT_ID, ScopeVars.scope_type == "host",
        ScopeVars.agent_id == body.consumer_agent_id))
    merged = dict((row.vars if row else {}) or {})
    stored: list[str] = []
    if body.targets.get("name") and produced.get("name"):
        merged[body.targets["name"]] = produced["name"]; stored.append(body.targets["name"])
    if body.targets.get("user") and produced.get("user"):
        merged[body.targets["user"]] = produced["user"]; stored.append(body.targets["user"])
    if body.targets.get("password"):
        merged[body.targets["password"]] = pw_handle; stored.append(body.targets["password"])
    if row is None:
        row = ScopeVars(tenant_id=DEFAULT_TENANT_ID, scope_type="host",
                        agent_id=body.consumer_agent_id, vars=merged)
        session.add(row)
    else:
        row.vars = merged
    await session.commit()
    return {"ok": True, "provider": provider.name, "consumer": consumer.name,
            "database": produced.get("name"), "user": produced.get("user"),
            "password_mode": body.password_mode, "stored_keys": stored, "password": Vault.mask()}


@router.post("/api/v1/blueprints/{bp_id}/save-as-runbook")
async def save_blueprint_as_runbook(bp_id: UUID, session: AsyncSession = Depends(get_session),
                                    settings: Settings = Depends(get_settings), identity: Identity = Depends(get_current_identity)):
    """Compile the blueprint and persist the typed playbook as a Runbook, so the
    stack can be run (run-runbook), bound to a scope (orchestration link), or
    delivered as a PXE target_runbook at boot. Idempotent on the runbook name."""
    from bossman.db.models import Runbook

    b = await session.get(Blueprint, bp_id)
    if b is None:
        raise HTTPException(404, "no such blueprint")
    from bossman.api.config_templates import load_template_bodies

    known = set(load_template_bodies(settings))
    fleet = await _resolve_fleet_providers(session, settings, list(b.services or []))
    vault = Vault(settings.vault_key, settings.vault_key_path)
    result = compile_blueprint(settings, b, known_templates=known, fleet_providers=fleet, vault=vault)
    doc = result["playbook"]
    name = doc["name"]
    rb = await session.scalar(select(Runbook).where(Runbook.name == name))
    if rb is None:
        rb = Runbook(tenant_id=DEFAULT_TENANT_ID, name=name, kind="runbook", folder="blueprints",
                     doc=doc, created_by=identity.name)
        session.add(rb)
    else:
        rb.doc = doc
    b.status = "ready"
    await session.commit()
    return {"runbook": name, "steps": len(doc["steps"]), "unresolved": result["unresolved"]}


class BindScopeIn(BaseModel):
    """Bind a blueprint to a scope so hosts in it get the stack as desired state —
    the path a PXE-booted host takes to come up already carrying the blueprint.
    Exactly one target id must match `target_type` (ou|site|group|host)."""
    target_type: str
    ou_id: UUID | None = None
    site_id: UUID | None = None
    host_group_id: UUID | None = None
    agent_id: UUID | None = None
    # Same approval posture as an orchestration link: pending_approval unless YOLO
    # mode is on, auto_apply is set, or approval is explicitly waived.
    auto_apply: bool = False
    require_approval: bool = True


@router.post("/api/v1/blueprints/{bp_id}/bind-to-scope")
async def bind_blueprint_to_scope(
    bp_id: UUID, body: BindScopeIn, session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings), identity: Identity = Depends(get_current_identity),
):
    """Compile the blueprint and bind it to an OU / Site / host-group / host as a
    `deployment` orchestration plan. The desired-state compiler then folds the
    stack into every host in that scope — so a freshly PXE-provisioned host that
    lands in the OU/Site comes up running the blueprint automatically, with no
    per-host step. Idempotent on the plan name: re-binding adds a new plan version.
    Honours the L2 approval gate (starts pending_approval unless YOLO / auto_apply).
    """
    b = await session.get(Blueprint, bp_id)
    if b is None:
        raise HTTPException(404, "no such blueprint")
    if body.target_type not in _BIND_TARGETS:
        raise HTTPException(422, f"target_type must be one of {_BIND_TARGETS}")
    ids = {"ou": body.ou_id, "site": body.site_id, "group": body.host_group_id, "host": body.agent_id}
    if ids[body.target_type] is None:
        raise HTTPException(422, f"target_type={body.target_type!r} requires the matching id field")
    if body.ou_id is not None and await session.get(OUNode, body.ou_id) is None:
        raise HTTPException(422, f"no such OU {body.ou_id}")
    if body.agent_id is not None and await session.get(Agent, body.agent_id) is None:
        raise HTTPException(422, f"no such host {body.agent_id}")
    if body.host_group_id is not None and await session.get(HostGroup, body.host_group_id) is None:
        raise HTTPException(422, f"no such host group {body.host_group_id}")

    from bossman.api.config_templates import load_template_bodies

    known = set(load_template_bodies(settings))
    fleet = await _resolve_fleet_providers(session, settings, list(b.services or []))
    vault = Vault(settings.vault_key, settings.vault_key_path)
    result = compile_blueprint(settings, b, known_templates=known, fleet_providers=fleet, vault=vault)
    doc = result["playbook"]
    steps = doc["steps"]

    # Upsert a deployment plan carrying the compiled steps. A new version on
    # re-bind means every follow-current link picks the change up on recompile.
    plan_name = doc["name"]
    plan = await session.scalar(select(OrchestrationPlan).where(OrchestrationPlan.name == plan_name))
    if plan is None:
        plan = OrchestrationPlan(
            id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=plan_name, display_name=b.name,
            description=b.description or f"Blueprint {b.name}", plan_type="deployment", current_version=1,
        )
        session.add(plan)
        session.add(OrchestrationPlanVersion(
            id=uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan.id, version=1, steps=steps))
    else:
        new_version = plan.current_version + 1
        session.add(OrchestrationPlanVersion(
            id=uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan.id, version=new_version, steps=steps))
        plan.current_version = new_version

    yolo = await is_yolo_mode(session)
    status = "active" if (yolo or body.auto_apply or not body.require_approval) else "pending_approval"
    link = OrchestrationPlanLink(
        id=uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan.id, status=status,
        target_type=body.target_type, ou_id=body.ou_id, site_id=body.site_id,
        host_group_id=body.host_group_id, agent_id=body.agent_id,
        auto_apply=body.auto_apply, require_approval=body.require_approval,
    )
    session.add(link)
    b.status = "ready"
    await session.commit()

    affected: list = []
    if status == "active":
        affected = await affected_agent_ids(
            session, body.target_type, ou_id=body.ou_id, agent_id=body.agent_id,
            host_group_id=body.host_group_id, site_id=body.site_id, tenant_id=DEFAULT_TENANT_ID)
        for aid in affected:
            await compile_host_desired_state(session, aid)
        await session.commit()

    return {"plan_id": str(plan.id), "plan_name": plan_name, "version": plan.current_version,
            "link_id": str(link.id), "status": status, "steps": len(steps),
            "affected_hosts": len(affected), "unresolved": result["unresolved"], "warnings": result["warnings"]}


@router.post("/api/v1/blueprints/seed-drafts")
async def seed_drafts(session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    """Install the sample blueprint drafts (idempotent)."""
    added = await seed_blueprint_drafts(session)
    await session.commit()
    return {"added": added}
