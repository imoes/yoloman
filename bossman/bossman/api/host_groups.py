"""Host group CRUD + membership (Block L1) — the first-class, many-to-many
group object of the AD model (distinct from the legacy flat
`Agent.groups` string list, which L1 deliberately leaves untouched). A
group lives inside an OU (ou_id) but a host can belong to any number of
groups, which is how a host gets cross-cutting assignments beyond its
single OU placement.
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
from bossman.db.models import Agent, HostGroup, HostGroupMember, OUNode
from bossman.db.session import get_session

router = APIRouter()

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


class HostGroupIn(BaseModel):
    name: str
    description: str = ""
    ou_id: UUID | None = None


class HostGroupOut(BaseModel):
    id: UUID
    name: str
    description: str
    ou_id: UUID | None
    created_at: datetime
    member_agent_ids: list[UUID]


async def _members(session: AsyncSession, group_id: UUID) -> list[UUID]:
    rows = (await session.scalars(select(HostGroupMember.agent_id).where(HostGroupMember.host_group_id == group_id))).all()
    return list(rows)


async def _to_out(session: AsyncSession, group: HostGroup) -> HostGroupOut:
    return HostGroupOut(
        id=group.id, name=group.name, description=group.description, ou_id=group.ou_id,
        created_at=group.created_at, member_agent_ids=await _members(session, group.id),
    )


async def _get_group_or_404(session: AsyncSession, group_id: UUID) -> HostGroup:
    group = await session.get(HostGroup, group_id)
    if group is None or group.deleted_at is not None:
        raise HTTPException(status_code=404, detail=f"no such host group {group_id}")
    return group


@router.get("/api/v1/host-groups", response_model=list[HostGroupOut])
async def list_host_groups(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[HostGroupOut]:
    rows = (
        await session.scalars(
            select(HostGroup).where(HostGroup.tenant_id == DEFAULT_TENANT_ID, HostGroup.deleted_at.is_(None)).order_by(HostGroup.name)
        )
    ).all()
    return [await _to_out(session, g) for g in rows]


@router.post("/api/v1/host-groups", response_model=HostGroupOut)
async def create_host_group(
    body: HostGroupIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> HostGroupOut:
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    group = HostGroup(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=body.name, description=body.description, ou_id=body.ou_id)
    session.add(group)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a host group named {body.name!r} already exists") from exc
    return await _to_out(session, group)


@router.put("/api/v1/host-groups/{group_id}", response_model=HostGroupOut)
async def update_host_group(
    group_id: UUID, body: HostGroupIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> HostGroupOut:
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    group = await _get_group_or_404(session, group_id)
    group.name = body.name
    group.description = body.description
    group.ou_id = body.ou_id
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a host group named {body.name!r} already exists") from exc
    return await _to_out(session, group)


class HostGroupPatch(BaseModel):
    # Re-scope the group to another OU (the palette drag-to-link gesture,
    # Block L3e) — a partial update that doesn't need name/description resent.
    ou_id: UUID | None = None


@router.patch("/api/v1/host-groups/{group_id}", response_model=HostGroupOut)
async def patch_host_group(
    group_id: UUID, body: HostGroupPatch, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> HostGroupOut:
    group = await _get_group_or_404(session, group_id)
    if body.ou_id is not None:
        if await session.get(OUNode, body.ou_id) is None:
            raise HTTPException(status_code=422, detail=f"no such OU {body.ou_id}")
        group.ou_id = body.ou_id
    await session.commit()
    return await _to_out(session, group)


@router.delete("/api/v1/host-groups/{group_id}", status_code=204)
async def delete_host_group(
    group_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    group = await _get_group_or_404(session, group_id)
    await session.delete(group)  # host_group_members is ON DELETE CASCADE
    await session.commit()


class GroupPolicyReportEntry(BaseModel):
    name: str
    type: str
    version: int | None
    member_count: int  # how many of the group's members this policy applies to


class GroupPolicyReport(BaseModel):
    group_id: UUID
    group_name: str
    member_count: int
    policies: list[GroupPolicyReportEntry]


@router.get("/api/v1/host-groups/{group_id}/policy-report", response_model=GroupPolicyReport)
async def host_group_policy_report(
    group_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> GroupPolicyReport:
    """Block O3 — which orchestration policies apply to this group's members.
    Iterates the members, compiles each one's (read-only) desired state via
    the same GPO resolver the host view uses, and unions the applied plans
    with a per-plan count of how many members they land on. Read-only; never
    persists a generation (uses the compiler's pure build half)."""
    from bossman.services.compiler import _build_desired_state

    group = await _get_group_or_404(session, group_id)
    member_ids = await _members(session, group_id)

    # plan name -> (type, version, set of member ids it applies to)
    agg: dict[str, dict] = {}
    for agent_id in member_ids:
        agent = await session.get(Agent, agent_id)
        if agent is None:
            continue
        state, _explain = await _build_desired_state(session, agent)
        for p in state["orchestration"]["plans"]:
            entry = agg.setdefault(p["name"], {"type": p["type"], "version": p["version"], "members": set()})
            entry["members"].add(agent_id)

    policies = [
        GroupPolicyReportEntry(name=name, type=e["type"], version=e["version"], member_count=len(e["members"]))
        for name, e in sorted(agg.items())
    ]
    return GroupPolicyReport(
        group_id=group_id, group_name=group.name, member_count=len(member_ids), policies=policies
    )


class MembershipIn(BaseModel):
    agent_ids: list[UUID]


@router.put("/api/v1/host-groups/{group_id}/members", response_model=HostGroupOut)
async def replace_host_group_members(
    group_id: UUID, body: MembershipIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> HostGroupOut:
    group = await _get_group_or_404(session, group_id)
    for agent_id in body.agent_ids:
        if await session.get(Agent, agent_id) is None:
            raise HTTPException(status_code=422, detail=f"no such agent {agent_id}")

    existing = (await session.scalars(select(HostGroupMember).where(HostGroupMember.host_group_id == group_id))).all()
    for row in existing:
        await session.delete(row)
    await session.flush()
    for agent_id in body.agent_ids:
        session.add(HostGroupMember(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, host_group_id=group_id, agent_id=agent_id))
    await session.commit()
    return await _to_out(session, group)
