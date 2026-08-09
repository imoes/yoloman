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

from bossman.api.auth import Identity, get_current_identity
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
)
from bossman.db.session import get_session
from bossman.services.blueprint import compile_blueprint, seed_blueprint_drafts
from bossman.services.compiler import (
    affected_agent_ids,
    compile_host_desired_state,
    is_yolo_mode,
)

router = APIRouter()

# The scope kinds a blueprint can be bound to (mirrors orchestration _TARGET_TYPES).
_BIND_TARGETS = ("ou", "site", "group", "host")


class BlueprintIn(BaseModel):
    name: str
    description: str = ""
    status: str = "draft"
    services: list = []


class BlueprintOut(BaseModel):
    id: UUID
    name: str
    description: str
    status: str
    services: list
    created_at: datetime
    updated_at: datetime

    @classmethod
    def of(cls, b: Blueprint) -> "BlueprintOut":
        return cls(id=b.id, name=b.name, description=b.description, status=b.status,
                   services=b.services or [], created_at=b.created_at, updated_at=b.updated_at)


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
                  status=body.status, services=body.services or [], created_by=identity.name)
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
    """Compile the blueprint into a typed playbook + wiring/order report."""
    b = await session.get(Blueprint, bp_id)
    if b is None:
        raise HTTPException(404, "no such blueprint")
    from bossman.api.config_templates import load_template_bodies

    known = set(load_template_bodies(settings))
    return compile_blueprint(settings, b, known_templates=known)


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
    result = compile_blueprint(settings, b, known_templates=known)
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
    result = compile_blueprint(settings, b, known_templates=known)
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
