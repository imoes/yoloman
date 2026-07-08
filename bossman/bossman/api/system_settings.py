"""Bossman-wide runtime toggles (Block L2) — currently just the global
"YOLO-MAN" mode switch for the Policy/Orchestration approval gate (see
services/compiler.is_yolo_mode / db.models.SystemSettings). DB-backed so
it flips instantly via this REST API/a future UI without a process
restart. Deliberately human-only: no MCP tool exposes a write for this —
see mcp/server.py.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import SYSTEM_SETTINGS_ID, SystemSettings
from bossman.db.session import get_session
from bossman.services.auth import Identity

router = APIRouter()


class SystemSettingsOut(BaseModel):
    yolo_mode: bool
    updated_by: str | None
    updated_at: datetime


async def _get_or_seed(session: AsyncSession) -> SystemSettings:
    settings = await session.get(SystemSettings, UUID(SYSTEM_SETTINGS_ID))
    if settings is None:
        # Defensive only — the L2 migration seeds this row unconditionally;
        # this branch exists so a hand-rolled test DB without that
        # migration having run doesn't crash the whole settings surface.
        settings = SystemSettings(id=UUID(SYSTEM_SETTINGS_ID), yolo_mode=False)
        session.add(settings)
        await session.commit()
    return settings


@router.get("/api/v1/system/yolo-mode", response_model=SystemSettingsOut)
async def get_yolo_mode(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> SystemSettingsOut:
    settings = await _get_or_seed(session)
    return SystemSettingsOut(yolo_mode=settings.yolo_mode, updated_by=settings.updated_by, updated_at=settings.updated_at)


class SetYoloModeIn(BaseModel):
    enabled: bool


@router.put("/api/v1/system/yolo-mode", response_model=SystemSettingsOut)
async def set_yolo_mode(
    body: SetYoloModeIn,
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> SystemSettingsOut:
    settings = await _get_or_seed(session)
    settings.yolo_mode = body.enabled
    settings.updated_by = identity.name
    await session.commit()
    return SystemSettingsOut(yolo_mode=settings.yolo_mode, updated_by=settings.updated_by, updated_at=settings.updated_at)
