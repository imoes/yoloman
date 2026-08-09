"""Value maps CRUD (Zabbix gap-analysis Block K4): reusable named numeric/
string -> label mappings, attachable to a CheckRule (see
services/monitoring.py's ServiceView.mapped_value) so a materialized
Service can show a human label ("Down"/"Up") alongside its raw value
(0/1), the way Zabbix's value maps work.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import ValueMap
from bossman.db.session import get_session

router = APIRouter()


class ValueMapIn(BaseModel):
    name: str
    mappings: dict[str, str]


class ValueMapOut(ValueMapIn):
    id: UUID
    created_at: datetime

    @classmethod
    def from_model(cls, vm: ValueMap) -> "ValueMapOut":
        return cls(id=vm.id, name=vm.name, mappings=vm.mappings, created_at=vm.created_at)


def _validate(body: ValueMapIn) -> None:
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    if not body.mappings:
        raise HTTPException(status_code=422, detail="mappings must not be empty")


@router.get("/api/v1/value-maps", response_model=list[ValueMapOut])
async def list_value_maps(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[ValueMapOut]:
    rows = (await session.scalars(select(ValueMap).order_by(ValueMap.name))).all()
    return [ValueMapOut.from_model(r) for r in rows]


@router.post("/api/v1/value-maps", response_model=ValueMapOut)
async def create_value_map(
    body: ValueMapIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> ValueMapOut:
    _validate(body)
    vm = ValueMap(name=body.name, mappings=body.mappings)
    session.add(vm)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a value map named {body.name!r} already exists") from exc
    return ValueMapOut.from_model(vm)


async def _get_value_map_or_404(session: AsyncSession, value_map_id: UUID) -> ValueMap:
    vm = await session.get(ValueMap, value_map_id)
    if vm is None:
        raise HTTPException(status_code=404, detail=f"no such value map {value_map_id}")
    return vm


@router.put("/api/v1/value-maps/{value_map_id}", response_model=ValueMapOut)
async def update_value_map(
    value_map_id: UUID,
    body: ValueMapIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> ValueMapOut:
    _validate(body)
    vm = await _get_value_map_or_404(session, value_map_id)
    vm.name = body.name
    vm.mappings = body.mappings
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a value map named {body.name!r} already exists") from exc
    return ValueMapOut.from_model(vm)


@router.delete("/api/v1/value-maps/{value_map_id}", status_code=204)
async def delete_value_map(
    value_map_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> None:
    vm = await _get_value_map_or_404(session, value_map_id)
    # check_rules.value_map_id is ON DELETE SET NULL at the DB level (see
    # the migration) — any rule referencing this map is detached, not
    # deleted, automatically.
    await session.delete(vm)
    await session.commit()
