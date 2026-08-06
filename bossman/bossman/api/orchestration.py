"""Orchestration plan CRUD, versions, links + compiled desired-state read
(Block L1). A plan is a stable named handle (docker_host, postgres_cluster,
...); its actual content lives in versioned OrchestrationPlanVersion rows.
Linking a plan to an OU/host/group/global scope makes services/compiler.py
pick it up on the next compile; creating or changing a link recompiles the
affected hosts immediately (mirrors templates.py's live-link/materialize
pattern), so GET .../desired-state always reflects the latest links.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import Agent, HostGroup, OrchestrationPlan, OrchestrationPlanLink, OrchestrationPlanVersion, OUNode
from bossman.db.session import get_session
from bossman.services.compiler import affected_agent_ids, compile_host_desired_state, compile_tenant, is_yolo_mode, preview_plan_link

router = APIRouter()

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")
_PLAN_TYPES = ("role", "cluster", "deployment", "remediation", "maintenance", "bootstrap")
_TARGET_TYPES = ("ou", "host", "group", "label_selector", "global")


# ---------------------------------------------------------------------------
# Plans + versions


class PlanVersionIn(BaseModel):
    parameter_schema: dict = {}
    default_parameters: dict = {}
    requirements: dict = {}
    steps: list = []
    rollback_steps: list = []
    validation_steps: list = []
    generated_monitoring: dict = {}
    generated_notifications: dict = {}


class PlanVersionOut(PlanVersionIn):
    id: UUID
    version: int
    created_at: datetime

    @classmethod
    def from_model(cls, v: OrchestrationPlanVersion) -> "PlanVersionOut":
        return cls(
            id=v.id, version=v.version, created_at=v.created_at, parameter_schema=v.parameter_schema,
            default_parameters=v.default_parameters, requirements=v.requirements, steps=v.steps,
            rollback_steps=v.rollback_steps, validation_steps=v.validation_steps,
            generated_monitoring=v.generated_monitoring, generated_notifications=v.generated_notifications,
        )


class PlanIn(BaseModel):
    name: str
    display_name: str
    description: str = ""
    plan_type: str
    version: PlanVersionIn = PlanVersionIn()


class PlanOut(BaseModel):
    id: UUID
    name: str
    display_name: str
    description: str
    plan_type: str
    enabled: bool
    current_version: int
    created_at: datetime
    versions: list[PlanVersionOut]

    @classmethod
    async def build(cls, session: AsyncSession, plan: OrchestrationPlan) -> "PlanOut":
        rows = (
            await session.scalars(
                select(OrchestrationPlanVersion).where(OrchestrationPlanVersion.plan_id == plan.id).order_by(OrchestrationPlanVersion.version)
            )
        ).all()
        return cls(
            id=plan.id, name=plan.name, display_name=plan.display_name, description=plan.description,
            plan_type=plan.plan_type, enabled=plan.enabled, current_version=plan.current_version,
            created_at=plan.created_at, versions=[PlanVersionOut.from_model(v) for v in rows],
        )


async def _get_plan_or_404(session: AsyncSession, plan_id: UUID) -> OrchestrationPlan:
    plan = await session.get(OrchestrationPlan, plan_id)
    if plan is None or plan.deleted_at is not None:
        raise HTTPException(status_code=404, detail=f"no such orchestration plan {plan_id}")
    return plan


@router.get("/api/v1/orchestration/plans", response_model=list[PlanOut])
async def list_plans(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[PlanOut]:
    rows = (
        await session.scalars(
            select(OrchestrationPlan).where(
                OrchestrationPlan.tenant_id == DEFAULT_TENANT_ID, OrchestrationPlan.deleted_at.is_(None)
            ).order_by(OrchestrationPlan.name)
        )
    ).all()
    return [await PlanOut.build(session, p) for p in rows]


@router.get("/api/v1/orchestration/plans/{plan_id}", response_model=PlanOut)
async def get_plan(
    plan_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> PlanOut:
    plan = await _get_plan_or_404(session, plan_id)
    return await PlanOut.build(session, plan)


@router.post("/api/v1/orchestration/plans", response_model=PlanOut)
async def create_plan(
    body: PlanIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> PlanOut:
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    if body.plan_type not in _PLAN_TYPES:
        raise HTTPException(status_code=422, detail=f"plan_type must be one of {_PLAN_TYPES}")

    plan = OrchestrationPlan(
        id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=body.name, display_name=body.display_name,
        description=body.description, plan_type=body.plan_type, current_version=1,
    )
    session.add(plan)
    session.add(OrchestrationPlanVersion(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan.id, version=1, **body.version.model_dump()))
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a plan named {body.name!r} already exists") from exc
    return await PlanOut.build(session, plan)


class PlanPatchIn(BaseModel):
    """Metadata-only edit of a policy/plan — rename or re-describe it. It deliberately does NOT touch the
    plan's versions/entries (that is what create_plan_version / the designer do), so editing an unlinked
    policy's label can never silently drop its content."""
    display_name: str | None = None
    description: str | None = None


@router.patch("/api/v1/orchestration/plans/{plan_id}", response_model=PlanOut)
async def update_plan(
    plan_id: UUID, body: PlanPatchIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> PlanOut:
    plan = await _get_plan_or_404(session, plan_id)
    if body.display_name is not None:
        plan.display_name = body.display_name
    if body.description is not None:
        plan.description = body.description
    await session.commit()
    return await PlanOut.build(session, plan)


@router.post("/api/v1/orchestration/plans/{plan_id}/versions", response_model=PlanOut)
async def create_plan_version(
    plan_id: UUID, body: PlanVersionIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> PlanOut:
    """Adds a new immutable version and makes it current — every host with
    a link that follows current_version (plan_version=NULL) picks it up on
    the next recompile, which this triggers immediately."""
    plan = await _get_plan_or_404(session, plan_id)
    new_version = plan.current_version + 1
    session.add(OrchestrationPlanVersion(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan.id, version=new_version, **body.model_dump()))
    plan.current_version = new_version
    await session.commit()
    await compile_tenant(session, DEFAULT_TENANT_ID)
    await session.commit()
    return await PlanOut.build(session, plan)


@router.delete("/api/v1/orchestration/plans/{plan_id}", status_code=204)
async def delete_plan(
    plan_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    plan = await _get_plan_or_404(session, plan_id)
    await session.delete(plan)  # versions + links are ON DELETE CASCADE
    await session.commit()
    await compile_tenant(session, DEFAULT_TENANT_ID)
    await session.commit()


# ---------------------------------------------------------------------------
# Plan links


class PlanLinkIn(BaseModel):
    plan_version: int | None = None
    target_type: str
    ou_id: UUID | None = None
    agent_id: UUID | None = None
    host_group_id: UUID | None = None
    parameters: dict = {}
    priority: int = 100
    link_order: int = 100
    enforced: bool = False
    auto_apply: bool = False
    require_approval: bool = True


class PlanLinkOut(PlanLinkIn):
    id: UUID
    plan_id: UUID
    enabled: bool
    status: str
    created_at: datetime

    @classmethod
    def from_model(cls, link: OrchestrationPlanLink) -> "PlanLinkOut":
        return cls(
            id=link.id, plan_id=link.plan_id, plan_version=link.plan_version, target_type=link.target_type,
            ou_id=link.ou_id, agent_id=link.agent_id, host_group_id=link.host_group_id, parameters=link.parameters,
            priority=link.priority, link_order=link.link_order, enforced=link.enforced, enabled=link.enabled,
            auto_apply=link.auto_apply, require_approval=link.require_approval, status=link.status,
            created_at=link.created_at,
        )


def _validate_link_target(body: PlanLinkIn) -> None:
    if body.target_type not in _TARGET_TYPES:
        raise HTTPException(status_code=422, detail=f"target_type must be one of {_TARGET_TYPES}")
    required = {"ou": body.ou_id, "host": body.agent_id, "group": body.host_group_id}
    if body.target_type in required and required[body.target_type] is None:
        raise HTTPException(status_code=422, detail=f"target_type={body.target_type!r} requires the matching id field")


async def _affected(session: AsyncSession, link: OrchestrationPlanLink) -> list[UUID]:
    return await affected_agent_ids(
        session, link.target_type, ou_id=link.ou_id, agent_id=link.agent_id,
        host_group_id=link.host_group_id, tenant_id=link.tenant_id,
    )


@router.get("/api/v1/orchestration/plans/{plan_id}/links", response_model=list[PlanLinkOut])
async def list_plan_links(
    plan_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[PlanLinkOut]:
    await _get_plan_or_404(session, plan_id)
    rows = (await session.scalars(select(OrchestrationPlanLink).where(OrchestrationPlanLink.plan_id == plan_id))).all()
    return [PlanLinkOut.from_model(link) for link in rows]


@router.get("/api/v1/orchestration/pending-links", response_model=list[PlanLinkOut])
async def list_pending_links(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[PlanLinkOut]:
    """Every link awaiting human approval, tenant-wide — the review queue
    an admin (or the MCP list_pending_orchestration_links tool, read-only)
    checks before deciding what to approve/reject."""
    rows = (
        await session.scalars(
            select(OrchestrationPlanLink).where(
                OrchestrationPlanLink.tenant_id == DEFAULT_TENANT_ID, OrchestrationPlanLink.status == "pending_approval"
            ).order_by(OrchestrationPlanLink.created_at)
        )
    ).all()
    return [PlanLinkOut.from_model(link) for link in rows]


class PlanLinkPreviewIn(BaseModel):
    plan_version: int | None = None
    target_type: str
    ou_id: UUID | None = None
    agent_id: UUID | None = None
    host_group_id: UUID | None = None
    parameters: dict = {}


@router.post("/api/v1/orchestration/plans/{plan_id}/preview-link")
async def preview_plan_link_endpoint(
    plan_id: UUID, body: PlanLinkPreviewIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> dict:
    """The safe "what would this link do" primitive (Block L2) — computes
    blast radius + a sample before/after monitoring diff WITHOUT persisting
    anything. Same underlying compiler.preview_plan_link the MCP dry-run
    tool calls."""
    await _get_plan_or_404(session, plan_id)
    result = await preview_plan_link(
        session, DEFAULT_TENANT_ID, plan_id, body.target_type, plan_version=body.plan_version,
        ou_id=body.ou_id, agent_id=body.agent_id, host_group_id=body.host_group_id, parameters=body.parameters,
    )
    if result is None:
        raise HTTPException(status_code=404, detail=f"no such orchestration plan {plan_id}")
    return result


@router.post("/api/v1/orchestration/plans/{plan_id}/links", response_model=PlanLinkOut)
async def create_plan_link(
    plan_id: UUID, body: PlanLinkIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> PlanLinkOut:
    """Block L2 approval gate: a link is created `active` immediately only
    if the global YOLO-MAN switch is on, or the link itself opts in via
    auto_apply / require_approval=false — otherwise it starts
    `pending_approval` and has no effect until POST .../approve. This is
    the one and only place that decides a link's initial status; the MCP
    write tool calls this same endpoint's underlying logic and can never
    pass auto_apply=true (see mcp/server.py)."""
    await _get_plan_or_404(session, plan_id)
    _validate_link_target(body)
    if body.ou_id is not None and await session.get(OUNode, body.ou_id) is None:
        raise HTTPException(status_code=422, detail=f"no such OU {body.ou_id}")
    if body.agent_id is not None and await session.get(Agent, body.agent_id) is None:
        raise HTTPException(status_code=422, detail=f"no such agent {body.agent_id}")
    if body.host_group_id is not None and await session.get(HostGroup, body.host_group_id) is None:
        raise HTTPException(status_code=422, detail=f"no such host group {body.host_group_id}")

    yolo = await is_yolo_mode(session)
    status = "active" if (yolo or body.auto_apply or not body.require_approval) else "pending_approval"

    link = OrchestrationPlanLink(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan_id, status=status, **body.model_dump())
    session.add(link)
    await session.commit()

    if status == "active":
        for agent_id in await _affected(session, link):
            await compile_host_desired_state(session, agent_id)
        await session.commit()
    return PlanLinkOut.from_model(link)


@router.post("/api/v1/orchestration/plans/{plan_id}/links/{link_id}/approve", response_model=PlanLinkOut)
async def approve_plan_link(
    plan_id: UUID, link_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> PlanLinkOut:
    link = await session.get(OrchestrationPlanLink, link_id)
    if link is None or link.plan_id != plan_id:
        raise HTTPException(status_code=404, detail=f"no such link {link_id} on plan {plan_id}")
    if link.status != "pending_approval":
        raise HTTPException(status_code=409, detail=f"link {link_id} is {link.status!r}, not pending_approval")
    link.status = "active"
    await session.commit()
    for agent_id in await _affected(session, link):
        await compile_host_desired_state(session, agent_id)
    await session.commit()
    return PlanLinkOut.from_model(link)


@router.post("/api/v1/orchestration/plans/{plan_id}/links/{link_id}/reject", response_model=PlanLinkOut)
async def reject_plan_link(
    plan_id: UUID, link_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> PlanLinkOut:
    link = await session.get(OrchestrationPlanLink, link_id)
    if link is None or link.plan_id != plan_id:
        raise HTTPException(status_code=404, detail=f"no such link {link_id} on plan {plan_id}")
    if link.status != "pending_approval":
        raise HTTPException(status_code=409, detail=f"link {link_id} is {link.status!r}, not pending_approval")
    link.status = "rejected"
    await session.commit()
    return PlanLinkOut.from_model(link)


@router.delete("/api/v1/orchestration/plans/{plan_id}/links/{link_id}", status_code=204)
async def delete_plan_link(
    plan_id: UUID, link_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    link = await session.get(OrchestrationPlanLink, link_id)
    if link is None or link.plan_id != plan_id:
        raise HTTPException(status_code=404, detail=f"no such link {link_id} on plan {plan_id}")
    await _delete_link(session, link)


@router.delete("/api/v1/orchestration/links/{link_id}", status_code=204)
async def delete_link_by_id(
    link_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    """Delete a plan link by its id alone (Block L3c) — the OU-tree console
    deletes an orchestration-link object without needing its plan id."""
    link = await session.get(OrchestrationPlanLink, link_id)
    if link is None:
        raise HTTPException(status_code=404, detail=f"no such link {link_id}")
    await _delete_link(session, link)


async def _delete_link(session: AsyncSession, link: OrchestrationPlanLink) -> None:
    was_active = link.status == "active"
    affected = await _affected(session, link) if was_active else []
    await session.delete(link)
    await session.commit()
    for agent_id in affected:
        await compile_host_desired_state(session, agent_id)
    await session.commit()


# ---------------------------------------------------------------------------
# Compiled desired state (read)


class CompiledStateOut(BaseModel):
    agent_id: UUID
    generation: int
    config_hash: str
    state: dict
    explain: dict


@router.get("/api/v1/agents/{agent_id}/desired-state", response_model=CompiledStateOut)
async def get_agent_desired_state(
    agent_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> CompiledStateOut:
    result = await compile_host_desired_state(session, agent_id)
    if result is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")
    await session.commit()
    return CompiledStateOut(
        agent_id=agent_id, generation=result.generation, config_hash=result.config_hash,
        state=result.state, explain=result.explain,
    )
