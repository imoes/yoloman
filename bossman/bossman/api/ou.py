"""OU tree CRUD (Block L1) — the AD-style organizational-unit hierarchy a
host lives at exactly one node of (Agent.ou_id). Every node's `path` is a
materialized slash-path recomputed from its ancestry on create/move, so
reads never need a recursive query.

Explicit select() queries throughout — no ORM relationship traversal
(matches services/templates.py's/compiler.py's MissingGreenlet-avoidance
convention from Block K11).
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

import re

from bossman.api.auth import get_current_identity
from bossman.db.models import (
    Agent,
    CheckRule,
    HostGroup,
    NotificationRule,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OUNode,
)
from bossman.db.session import get_session
from bossman.services.compiler import affected_agent_ids, compile_host_desired_state, resolve_ou_ancestry

router = APIRouter()


def _ltree_segment(name: str) -> str:
    """Sanitize an OU display name into a single ltree label (PG16 allows
    [A-Za-z0-9_-]; everything else, including spaces, becomes '_'). A blank
    result falls back to '_' so the label is always valid."""
    seg = re.sub(r"[^A-Za-z0-9_-]", "_", name.strip())
    return seg or "_"

# L1 is single-tenant-aware but not multi-tenant-selectable yet — every
# request implicitly operates on the seeded default tenant, matching how
# the rest of Bossman's REST surface has no tenant selector either. A
# tenant-picking UI/API is out of scope until a real second tenant exists.
DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


class OUNodeIn(BaseModel):
    name: str
    parent_id: UUID | None = None


class OUNodeOut(BaseModel):
    id: UUID
    parent_id: UUID | None
    name: str
    path: str
    ltree_path: str
    block_inheritance: bool
    created_at: datetime

    @classmethod
    def from_model(cls, node: OUNode) -> "OUNodeOut":
        return cls(
            id=node.id, parent_id=node.parent_id, name=node.name, path=node.path,
            ltree_path=str(node.ltree_path), block_inheritance=node.block_inheritance, created_at=node.created_at,
        )


async def _get_ou_or_404(session: AsyncSession, ou_id: UUID) -> OUNode:
    node = await session.get(OUNode, ou_id)
    if node is None or node.tenant_id != DEFAULT_TENANT_ID:
        raise HTTPException(status_code=404, detail=f"no such OU node {ou_id}")
    return node


@router.get("/api/v1/ou", response_model=list[OUNodeOut])
async def list_ou_nodes(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[OUNodeOut]:
    rows = (
        await session.scalars(
            select(OUNode).where(OUNode.tenant_id == DEFAULT_TENANT_ID, OUNode.deleted_at.is_(None)).order_by(OUNode.path)
        )
    ).all()
    return [OUNodeOut.from_model(n) for n in rows]


@router.post("/api/v1/ou", response_model=OUNodeOut)
async def create_ou_node(
    body: OUNodeIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> OUNodeOut:
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    parent_path = ""
    parent_ltree = ""
    if body.parent_id is not None:
        parent = await _get_ou_or_404(session, body.parent_id)
        parent_path = parent.path
        parent_ltree = str(parent.ltree_path)
    segment = _ltree_segment(body.name)
    ltree_path = f"{parent_ltree}.{segment}" if parent_ltree else segment
    node = OUNode(
        id=uuid4(), tenant_id=DEFAULT_TENANT_ID, parent_id=body.parent_id, name=body.name,
        path=f"{parent_path}/{body.name}", ltree_path=ltree_path,
    )
    session.add(node)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"an OU named {body.name!r} already exists under this parent") from exc
    return OUNodeOut.from_model(node)


class OUNodePatch(BaseModel):
    block_inheritance: bool


@router.patch("/api/v1/ou/{ou_id}", response_model=OUNodeOut)
async def patch_ou_node(
    ou_id: UUID,
    body: OUNodePatch,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> OUNodeOut:
    """Toggle GPO "Block Inheritance" on an OU. Since this changes which
    inherited rules apply to every host in this OU's subtree, it recompiles
    them all (analogous to a plan-link change)."""
    node = await _get_ou_or_404(session, ou_id)
    node.block_inheritance = body.block_inheritance
    await session.commit()
    for agent_id in await affected_agent_ids(session, "ou", ou_id=ou_id, tenant_id=DEFAULT_TENANT_ID):
        await compile_host_desired_state(session, agent_id)
    await session.commit()
    return OUNodeOut.from_model(node)


@router.delete("/api/v1/ou/{ou_id}", status_code=204)
async def delete_ou_node(
    ou_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    node = await _get_ou_or_404(session, ou_id)
    child = await session.scalar(select(OUNode.id).where(OUNode.parent_id == ou_id))
    if child is not None:
        raise HTTPException(status_code=409, detail="cannot delete an OU that still has child OUs")
    hosted = await session.scalar(select(Agent.id).where(Agent.ou_id == ou_id))
    if hosted is not None:
        raise HTTPException(status_code=409, detail="cannot delete an OU that still has hosts placed in it")
    await session.delete(node)
    await session.commit()


@router.get("/api/v1/ou/{ou_id}/ancestry", response_model=list[OUNodeOut])
async def get_ou_ancestry(
    ou_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[OUNodeOut]:
    await _get_ou_or_404(session, ou_id)
    chain = await resolve_ou_ancestry(session, ou_id)
    return [OUNodeOut.from_model(n) for n in chain]


class OUObject(BaseModel):
    """One policy object directly attached to an OU (Block L3a) — the tree
    UI's per-node child list. `kind` discriminates the object type; the
    common GPO fields (enforced/enabled) drive the tree's status markers."""

    kind: str  # check_rule | notification | host_group | orchestration_link
    id: UUID
    label: str
    enforced: bool = False
    enabled: bool = True


@router.get("/api/v1/ou/{ou_id}/objects", response_model=list[OUObject])
async def list_ou_objects(
    ou_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[OUObject]:
    """Every policy object attached DIRECTLY to this OU (not inherited) —
    check-rules/thresholds, notification rules, host groups, and
    orchestration plan links — the child nodes the GPO tree shows under an
    OU. Inheritance/effective resolution is a separate concern (the
    compiler / desired-state view)."""
    await _get_ou_or_404(session, ou_id)
    out: list[OUObject] = []

    for r in (await session.scalars(select(CheckRule).where(CheckRule.scope_ou_id == ou_id))).all():
        label = f"{r.service_name} ({r.metric} {r.comparison} {r.warn_threshold}/{r.crit_threshold})"
        out.append(OUObject(kind="check_rule", id=r.id, label=label, enforced=r.enforced, enabled=r.enabled))

    for n in (await session.scalars(select(NotificationRule).where(NotificationRule.ou_id == ou_id))).all():
        out.append(
            OUObject(kind="notification", id=n.id, label=f"{n.name} → {n.channel}", enforced=n.enforced, enabled=n.enabled)
        )

    for g in (await session.scalars(select(HostGroup).where(HostGroup.ou_id == ou_id, HostGroup.deleted_at.is_(None)))).all():
        out.append(OUObject(kind="host_group", id=g.id, label=g.name))

    links = (await session.scalars(select(OrchestrationPlanLink).where(OrchestrationPlanLink.ou_id == ou_id))).all()
    for link in links:
        plan = await session.get(OrchestrationPlan, link.plan_id)
        label = f"{plan.display_name if plan else link.plan_id} [{link.status}]"
        out.append(
            OUObject(kind="orchestration_link", id=link.id, label=label, enforced=link.enforced, enabled=link.enabled)
        )
    return out


class AssignHostOUIn(BaseModel):
    ou_id: UUID | None


@router.put("/api/v1/agents/{agent_id}/ou", response_model=OUNodeOut | None)
async def assign_agent_ou(
    agent_id: UUID,
    body: AssignHostOUIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> OUNodeOut | None:
    """A host lives at exactly one OU (the AD model) — setting it here
    replaces any prior placement rather than adding to it. NULL un-places
    the host (root/unassigned)."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")
    if body.ou_id is not None:
        node = await _get_ou_or_404(session, body.ou_id)
        agent.ou_id = node.id
        await session.commit()
        return OUNodeOut.from_model(node)
    agent.ou_id = None
    await session.commit()
    return None
