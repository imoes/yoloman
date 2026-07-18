"""Certificate / expiry inventory API (gap #10): CRUD for cert targets, a
check-now probe, and a status summary for the dashboard.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.models import CertTarget
from bossman.db.session import get_session
from bossman.services import cert_inventory

router = APIRouter()
DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")
_RANK = {"expired": 0, "critical": 1, "error": 2, "warning": 3, "unknown": 4, "ok": 5}


class CertTargetIn(BaseModel):
    name: str
    enabled: bool = True
    kind: str = "tls"  # tls | manual
    endpoint: str = ""
    warn_days: int = 30
    crit_days: int = 7
    not_after: datetime | None = None  # required for manual


class CertTargetOut(BaseModel):
    id: UUID
    name: str
    enabled: bool
    kind: str
    endpoint: str
    warn_days: int
    crit_days: int
    subject: str | None
    issuer: str | None
    serial: str | None
    not_before: datetime | None
    not_after: datetime | None
    sans: list
    days_left: int | None
    status: str
    last_error: str | None
    last_checked_at: datetime | None

    @classmethod
    def of(cls, t: CertTarget) -> "CertTargetOut":
        return cls(
            id=t.id, name=t.name, enabled=t.enabled, kind=t.kind, endpoint=t.endpoint,
            warn_days=t.warn_days, crit_days=t.crit_days, subject=t.subject, issuer=t.issuer,
            serial=t.serial, not_before=t.not_before, not_after=t.not_after, sans=t.sans or [],
            days_left=t.days_left, status=t.status, last_error=t.last_error, last_checked_at=t.last_checked_at,
        )


def _validate(body: CertTargetIn) -> None:
    if body.kind not in ("tls", "manual"):
        raise HTTPException(422, "kind must be tls|manual")
    if body.kind == "tls" and not body.endpoint.strip():
        raise HTTPException(422, "a tls target needs an endpoint")
    if body.kind == "manual" and body.not_after is None:
        raise HTTPException(422, "a manual target needs an expiry date (not_after)")


def _sorted(rows: list[CertTarget]) -> list[CertTarget]:
    # Worst status first, then soonest expiry (nulls last).
    return sorted(rows, key=lambda t: (_RANK.get(t.status, 9), t.days_left if t.days_left is not None else 10**9))


@router.get("/api/v1/cert-targets", response_model=list[CertTargetOut])
async def list_targets(session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    rows = (await session.scalars(select(CertTarget))).all()
    return [CertTargetOut.of(t) for t in _sorted(list(rows))]


@router.get("/api/v1/cert-targets/summary")
async def summary(session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    rows = (await session.execute(
        select(CertTarget.status, func.count()).group_by(CertTarget.status)
    )).all()
    counts = {s: n for s, n in rows}
    return {"total": sum(counts.values()), "by_status": counts}


@router.post("/api/v1/cert-targets", response_model=CertTargetOut)
async def create_target(body: CertTargetIn, session: AsyncSession = Depends(get_session),
                        settings: Settings = Depends(get_settings), identity: Identity = Depends(get_current_identity)):
    _validate(body)
    t = CertTarget(
        tenant_id=DEFAULT_TENANT_ID, name=body.name, enabled=body.enabled, kind=body.kind,
        endpoint=body.endpoint.strip(), warn_days=body.warn_days, crit_days=body.crit_days,
        not_after=body.not_after, created_by=identity.name,
    )
    session.add(t)
    await session.flush()
    # Probe/compute immediately so the dashboard shows a result at once.
    await cert_inventory.evaluate_target(session, settings, t, commit=False)
    await session.commit()
    await session.refresh(t)
    return CertTargetOut.of(t)


@router.put("/api/v1/cert-targets/{target_id}", response_model=CertTargetOut)
async def update_target(target_id: UUID, body: CertTargetIn, session: AsyncSession = Depends(get_session),
                        settings: Settings = Depends(get_settings), _i: Identity = Depends(get_current_identity)):
    t = await session.get(CertTarget, target_id)
    if t is None:
        raise HTTPException(404, "no such target")
    _validate(body)
    t.name, t.enabled, t.kind, t.endpoint = body.name, body.enabled, body.kind, body.endpoint.strip()
    t.warn_days, t.crit_days = body.warn_days, body.crit_days
    if body.kind == "manual":
        t.not_after = body.not_after
    await cert_inventory.evaluate_target(session, settings, t, commit=False)
    await session.commit()
    await session.refresh(t)
    return CertTargetOut.of(t)


@router.post("/api/v1/cert-targets/{target_id}/check", response_model=CertTargetOut)
async def check_target(target_id: UUID, session: AsyncSession = Depends(get_session),
                       settings: Settings = Depends(get_settings), _i: Identity = Depends(get_current_identity)):
    t = await session.get(CertTarget, target_id)
    if t is None:
        raise HTTPException(404, "no such target")
    await cert_inventory.evaluate_target(session, settings, t)
    await session.refresh(t)
    return CertTargetOut.of(t)


@router.delete("/api/v1/cert-targets/{target_id}", status_code=204)
async def delete_target(target_id: UUID, session: AsyncSession = Depends(get_session),
                        _i: Identity = Depends(get_current_identity)):
    t = await session.get(CertTarget, target_id)
    if t is not None:
        await session.delete(t)
        await session.commit()
