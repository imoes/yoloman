"""Audit-log API (gap #13): a searchable who-did-what-when trail. Admin-only —
the audit record is sensitive (it names actors, IPs, and targets).
"""

from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, require_admin
from bossman.db.models import AuditLog
from bossman.db.session import get_session

router = APIRouter()


class AuditOut(BaseModel):
    id: int
    at: datetime
    actor: str
    actor_kind: str | None
    action: str
    category: str
    method: str | None
    path: str | None
    target: str | None
    status: str
    status_code: int | None
    source_ip: str | None
    detail: dict

    @classmethod
    def of(cls, r: AuditLog) -> "AuditOut":
        return cls(
            id=r.id, at=r.at, actor=r.actor, actor_kind=r.actor_kind, action=r.action,
            category=r.category, method=r.method, path=r.path, target=r.target,
            status=r.status, status_code=r.status_code, source_ip=r.source_ip, detail=r.detail or {},
        )


@router.get("/api/v1/audit", response_model=list[AuditOut])
async def list_audit(
    actor: str | None = Query(None),
    category: str | None = Query(None),
    status: str | None = Query(None),
    q: str | None = Query(None, description="substring match on action/path/target"),
    since: datetime | None = Query(None),
    limit: int = Query(100, le=1000),
    session: AsyncSession = Depends(get_session),
    _admin: Identity = Depends(require_admin),
):
    stmt = select(AuditLog).order_by(AuditLog.at.desc(), AuditLog.id.desc())
    if actor:
        stmt = stmt.where(AuditLog.actor == actor)
    if category:
        stmt = stmt.where(AuditLog.category == category)
    if status:
        stmt = stmt.where(AuditLog.status == status)
    if since:
        stmt = stmt.where(AuditLog.at >= since)
    if q:
        like = f"%{q}%"
        stmt = stmt.where(AuditLog.action.ilike(like) | AuditLog.path.ilike(like) | AuditLog.target.ilike(like))
    rows = (await session.scalars(stmt.limit(limit))).all()
    return [AuditOut.of(r) for r in rows]


@router.get("/api/v1/audit/stats")
async def audit_stats(session: AsyncSession = Depends(get_session), _admin: Identity = Depends(require_admin)):
    total = await session.scalar(select(func.count()).select_from(AuditLog)) or 0
    by_cat = (await session.execute(
        select(AuditLog.category, func.count()).group_by(AuditLog.category)
    )).all()
    failures = await session.scalar(
        select(func.count()).select_from(AuditLog).where(AuditLog.status == "failed")
    ) or 0
    return {"total": total, "failed": failures, "by_category": {c: n for c, n in by_cat}}
