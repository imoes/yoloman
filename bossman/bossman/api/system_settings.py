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

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.config import get_settings
from bossman.db.models import SYSTEM_SETTINGS_ID, SystemSettings
from bossman.db.session import get_session
from bossman.services import helm_app
from bossman.services.auth import Identity

router = APIRouter()


class SystemSettingsOut(BaseModel):
    yolo_mode: bool
    helm_http_proxy: str
    helm_no_proxy: str
    # The netboot secret's plaintext is NEVER returned — only whether one is set + the enable toggle.
    netboot_enabled: bool
    netboot_secret_set: bool
    # Event/run history retention (days); 0 = keep forever. Housekeeping prunes older runbook_runs + audit.
    run_retention_days: int
    updated_by: str | None
    updated_at: datetime


def _out(s: SystemSettings) -> "SystemSettingsOut":
    return SystemSettingsOut(
        yolo_mode=s.yolo_mode,
        helm_http_proxy=s.helm_http_proxy or "",
        helm_no_proxy=s.helm_no_proxy or "",
        netboot_enabled=s.netboot_enabled,
        netboot_secret_set=bool(s.netboot_secret),
        run_retention_days=s.run_retention_days,
        updated_by=s.updated_by,
        updated_at=s.updated_at,
    )


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
    return _out(settings)


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
    return _out(settings)


class SetNetbootIn(BaseModel):
    enabled: bool
    # Optional: only rotates the stored secret when a non-null value is sent; the UI never receives the
    # current plaintext, so omitting it keeps the existing secret. "" explicitly clears it.
    secret: str | None = None


@router.put("/api/v1/system/netboot", response_model=SystemSettingsOut)
async def set_netboot(
    body: SetNetbootIn,
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> SystemSettingsOut:
    """Enter/rotate the PXE netboot secret and turn netboot on/off. Enabling without any secret set
    (neither here nor the BOSSMAN_NETBOOT_SECRET env fallback) is rejected — an open install endpoint
    must never be a one-click mistake."""
    settings = await _get_or_seed(session)
    if body.secret is not None:
        settings.netboot_secret = body.secret
    if body.enabled and not (settings.netboot_secret or get_settings().netboot_secret):
        raise HTTPException(status_code=400, detail="cannot enable netboot without a secret set")
    settings.netboot_enabled = body.enabled
    settings.updated_by = identity.name
    await session.commit()
    return _out(settings)


class SetRetentionIn(BaseModel):
    # Days of event/run history to keep; 0 = forever. Clamped to a sane range.
    run_retention_days: int


@router.put("/api/v1/system/retention", response_model=SystemSettingsOut)
async def set_retention(
    body: SetRetentionIn,
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> SystemSettingsOut:
    """Set the event/run history retention window (Admin settings). Housekeeping's
    hourly sweep prunes runbook_runs + audit_log rows older than this many days;
    0 disables auto-purge (keep forever). The Event Browser also offers a manual
    purge that ignores this window."""
    days = max(0, min(int(body.run_retention_days), 3650))
    settings = await _get_or_seed(session)
    settings.run_retention_days = days
    settings.updated_by = identity.name
    await session.commit()
    return _out(settings)


class SetHelmProxyIn(BaseModel):
    http_proxy: str = ""
    no_proxy: str = ""


@router.put("/api/v1/system/helm-proxy", response_model=SystemSettingsOut)
async def set_helm_proxy(
    body: SetHelmProxyIn,
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> SystemSettingsOut:
    """Set the Bossman-wide helm chart-pull proxy (edited in Admin Settings). Writes
    the DB row AND refreshes the in-process cache so the next helm command uses it
    immediately, without a restart — see services/helm_app.set_helm_proxy."""
    settings = await _get_or_seed(session)
    settings.helm_http_proxy = (body.http_proxy or "").strip()
    settings.helm_no_proxy = (body.no_proxy or "").strip()
    settings.updated_by = identity.name
    await session.commit()
    helm_app.set_helm_proxy(settings.helm_http_proxy, settings.helm_no_proxy)
    return _out(settings)
