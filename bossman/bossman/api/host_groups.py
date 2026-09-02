"""Host group CRUD + membership — the first-class, many-to-many group object (distinct from the
legacy flat `Agent.groups` string list, which stays untouched).

A group is PLACELESS: it has no position in the OU tree. A host has one location (agents.ou_id) and
many properties; the group is a property, which is what lets it cut across the tree. See the
HostGroup model docstring for why the former `ou_id` was removed and how Windows does the same.
"""

from __future__ import annotations

import logging

from datetime import datetime
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import Agent, HostGroup, HostGroupMember
from bossman.db.session import get_session
from bossman.services import host_membership

logger = logging.getLogger(__name__)

router = APIRouter()

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


class HostGroupIn(BaseModel):
    name: str
    description: str = ""


class HostGroupOut(BaseModel):
    id: UUID
    name: str
    description: str
    created_at: datetime
    member_agent_ids: list[UUID]


async def _members(session: AsyncSession, group_id: UUID) -> list[UUID]:
    rows = (await session.scalars(select(HostGroupMember.agent_id).where(HostGroupMember.host_group_id == group_id))).all()
    return list(rows)


async def _to_out(session: AsyncSession, group: HostGroup) -> HostGroupOut:
    return HostGroupOut(
        id=group.id, name=group.name, description=group.description,
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
    """Host groups — a first-class, many-to-many set of hosts, and **placeless** on purpose.

    A group has no position in the OU tree: a host has one *location* (its OU) and many
    *properties*, and a group is a property. That is what lets a group cut across the tree, and it is
    why the former `ou_id` on this object was removed rather than kept "for convenience".

    Distinct from the legacy flat `Agent.groups` string list, which is a **projection** this API
    maintains — see `replace_host_group_members` for why that matters.
    """
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
    """Create a host group. Empty until members are set; an empty group matches no rule."""
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    group = HostGroup(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=body.name, description=body.description)
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
    """Rename or re-describe a group.

    A rename also re-derives the projected `agents.groups` array of every member, because rule
    matching reads that array rather than the membership rows. Renaming the row alone would leave
    every member matching the old name.
    """
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    group = await _get_group_or_404(session, group_id)
    # A rename carries its references: the name IS what check rules, notification rules,
    # template links and the projected agents.groups point at, and matching is path-based on
    # it. Renaming only this row left rules aimed at a name that no longer existed — proven
    # live, see services/host_membership.rename_group.
    try:
        renamed = await host_membership.rename_group(session, group, body.name)
    except host_membership.RenameCollision as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    group.description = body.description
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a host group named {body.name!r} already exists") from exc
    if renamed:
        logger.info("host group rename carried references: %s", renamed)
    return await _to_out(session, group)


# The PATCH endpoint that lived here existed for ONE purpose: re-scoping a group to another OU
# (the drag-to-link gesture in the OU palette). A group has no place in the OU tree any more — see
# the HostGroup model docstring — so the endpoint went with the field rather than being left as a
# no-op that silently accepts a body it cannot honour.


@router.delete("/api/v1/host-groups/{group_id}", status_code=204)
async def delete_host_group(
    group_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    """Delete a group, and take its name out of every former member's projection.

    The membership rows cascade, but that is not enough: rule matching reads the projected
    `agents.groups` array, so a former member would keep matching a group that no longer exists. The
    members are collected **before** the delete and re-projected after — and their *other* groups are
    adopted first, while this one still exists, because adopting afterwards would see this group's
    name in the arrays with no row behind it and re-create the very group being deleted.

    Rules scoped to this group stop matching anything. They are not deleted: a policy whose scope
    vanished is still a policy someone wrote.
    """
    group = await _get_group_or_404(session, group_id)
    # Remember the members BEFORE the cascade removes the rows, then rebuild their projected
    # `agents.groups` after the delete — otherwise every former member keeps the group's name
    # in the array rule matching reads, i.e. keeps matching a group that no longer exists.
    # Found by measuring the delete right after fixing add/rename, not by inspection.
    member_ids = list(
        (
            await session.scalars(
                select(HostGroupMember.agent_id).where(HostGroupMember.host_group_id == group_id)
            )
        ).all()
    )
    # Adopt BEFORE the delete, while this group still exists: adopting afterwards would see
    # its name in the members' arrays with no row behind it and re-create the group we are
    # deleting. Adopting first only protects the members' OTHER groups; the cascade then
    # removes this one and the re-projection drops its name.
    for agent_id in member_ids:
        agent = await session.get(Agent, agent_id)
        if agent is not None:
            await host_membership.adopt_projection(session, agent)
    await session.flush()
    await session.delete(group)  # host_group_members is ON DELETE CASCADE
    await session.flush()
    for agent_id in member_ids:
        agent = await session.get(Agent, agent_id)
        if agent is not None:
            await host_membership.project_agent_groups(session, agent)
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
    """Replace the group's membership wholesale — hosts not in the list are removed from it.

    422 naming any agent id that does not exist, checked before anything is written, so a typo cannot
    half-apply a membership change.

    **Two things are written, not one.** The membership rows AND the projected `agents.groups` array
    that rule matching actually reads. Writing only the rows — which this endpoint used to do — left
    a host displayed as a member that the group's own rules did not match. That is the kind of defect
    that looks like a monitoring gap for weeks.
    """
    group = await _get_group_or_404(session, group_id)
    for agent_id in body.agent_ids:
        if await session.get(Agent, agent_id) is None:
            raise HTTPException(status_code=422, detail=f"no such agent {agent_id}")

    # services/host_membership owns this write: it replaces the membership rows AND
    # re-derives `agents.groups` for every host that gains or loses the group. Writing only
    # the rows (as this did) left rule matching on the old projection, so a host shown as a
    # member was not matched by the group's rules.
    await host_membership.set_group_members(session, group, list(body.agent_ids))
    await session.commit()
    return await _to_out(session, group)
