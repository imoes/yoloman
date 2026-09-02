"""Business/logical service API (gap #4): CRUD for aggregated services + a
run-now recompute. Each service rolls a state up from many underlying services.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.models import BusinessService
from bossman.db.session import get_session
from bossman.services import business_service

router = APIRouter()
DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


class Member(BaseModel):
    scope_type: str = "global"  # global | host | group | ou
    agent_id: UUID | None = None
    host_group_id: UUID | None = None
    ou_id: UUID | None = None
    service_name: str | None = None  # substring match; empty = all services on the scope


class BusinessServiceIn(BaseModel):
    name: str
    description: str | None = None
    enabled: bool = True
    members: list[Member] = []
    logic: str = "all"  # all (AND/worst) | any (OR/best)


class BusinessServiceOut(BaseModel):
    id: UUID
    name: str
    description: str | None
    enabled: bool
    members: list
    logic: str
    status: str
    summary: dict
    last_evaluated_at: datetime | None
    created_at: datetime
    updated_at: datetime

    @classmethod
    def of(cls, b: BusinessService) -> "BusinessServiceOut":
        return cls(
            id=b.id, name=b.name, description=b.description, enabled=b.enabled, members=b.members or [],
            logic=b.logic, status=b.status, summary=b.summary or {}, last_evaluated_at=b.last_evaluated_at,
            created_at=b.created_at, updated_at=b.updated_at,
        )


def _validate(body: BusinessServiceIn) -> None:
    if body.logic not in ("all", "any"):
        raise HTTPException(422, "logic must be all|any")
    if not body.members:
        raise HTTPException(422, "a business service needs at least one member selector")
    for m in body.members:
        if m.scope_type not in ("global", "host", "group", "ou"):
            raise HTTPException(422, "member scope_type must be global|host|group|ou")
        if m.scope_type == "host" and not m.agent_id:
            raise HTTPException(422, "host member needs agent_id")
        if m.scope_type == "group" and not m.host_group_id:
            raise HTTPException(422, "group member needs host_group_id")
        if m.scope_type == "ou" and not m.ou_id:
            raise HTTPException(422, "ou member needs ou_id")


def _members_json(body: BusinessServiceIn) -> list:
    out = []
    for m in body.members:
        out.append({
            "scope_type": m.scope_type,
            "agent_id": str(m.agent_id) if m.agent_id else None,
            "host_group_id": str(m.host_group_id) if m.host_group_id else None,
            "ou_id": str(m.ou_id) if m.ou_id else None,
            "service_name": m.service_name or None,
        })
    return out


@router.get("/api/v1/business-services", response_model=list[BusinessServiceOut])
async def list_bs(session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    """Business services: one state rolled up from many technical ones.

    A member is a **scope selector** (host, group, OU, global, optionally filtered by service name)
    rather than a fixed list, so a host joining a group joins the aggregate too. `logic` is `all`
    (worst-of — every member matters) or `any` (redundancy — one healthy member is enough).

    The rolled-up status and the per-member breakdown are recomputed on a cycle; the breakdown is
    what makes the rollup explainable rather than a colour nobody can trace.
    """
    rows = (await session.scalars(select(BusinessService).order_by(BusinessService.name))).all()
    return [BusinessServiceOut.of(b) for b in rows]


@router.post("/api/v1/business-services", response_model=BusinessServiceOut)
async def create_bs(body: BusinessServiceIn, session: AsyncSession = Depends(get_session),
                    settings: Settings = Depends(get_settings), identity: Identity = Depends(get_current_identity)):
    """Create an aggregate — and it is evaluated immediately, in the same transaction.

    So the response already carries a real state rather than a placeholder that resolves on the next
    cycle. `logic: all` means the aggregate is as bad as its worst member; `logic: any` means it is
    healthy while at least one member is.

    Choosing between them is a statement about the *system*, not a display preference: `any` on a
    non-redundant service reports healthy while half of it is down.
    """
    _validate(body)
    b = BusinessService(
        tenant_id=DEFAULT_TENANT_ID, name=body.name, description=body.description, enabled=body.enabled,
        members=_members_json(body), logic=body.logic, created_by=identity.name,
    )
    session.add(b)
    await session.flush()
    await business_service.evaluate_business_service(session, settings, b, commit=False)
    await session.commit()
    await session.refresh(b)
    return BusinessServiceOut.of(b)


@router.put("/api/v1/business-services/{bs_id}", response_model=BusinessServiceOut)
async def update_bs(bs_id: UUID, body: BusinessServiceIn, session: AsyncSession = Depends(get_session),
                    settings: Settings = Depends(get_settings), _i: Identity = Depends(get_current_identity)):
    """Replace an aggregate's members or logic. Omitted fields are cleared.

    The state is recomputed on the next cycle rather than here — use `.../evaluate` if you need the
    new definition's verdict now.
    """
    b = await session.get(BusinessService, bs_id)
    if b is None:
        raise HTTPException(404, "no such business service")
    _validate(body)
    b.name, b.description, b.enabled = body.name, body.description, body.enabled
    b.members, b.logic = _members_json(body), body.logic
    await business_service.evaluate_business_service(session, settings, b, commit=False)
    await session.commit()
    await session.refresh(b)
    return BusinessServiceOut.of(b)


@router.post("/api/v1/business-services/{bs_id}/evaluate", response_model=BusinessServiceOut)
async def evaluate_bs(bs_id: UUID, session: AsyncSession = Depends(get_session),
                      settings: Settings = Depends(get_settings), _i: Identity = Depends(get_current_identity)):
    """Recompute this aggregate now and return the result.

    Reads the member services' **current stored states** — it does not re-run any check, so the
    answer is as fresh as the last monitoring cycle. 404 for an unknown id. Running this by hand does
    not change the periodic schedule.
    """
    b = await session.get(BusinessService, bs_id)
    if b is None:
        raise HTTPException(404, "no such business service")
    await business_service.evaluate_business_service(session, settings, b)
    await session.refresh(b)
    return BusinessServiceOut.of(b)


@router.delete("/api/v1/business-services/{bs_id}", status_code=204)
async def delete_bs(bs_id: UUID, session: AsyncSession = Depends(get_session),
                    _i: Identity = Depends(get_current_identity)):
    """Delete an aggregate. Its member services are untouched: an aggregate is a view over
    them, not a container of them."""
    b = await session.get(BusinessService, bs_id)
    if b is not None:
        await session.delete(b)
        await session.commit()
