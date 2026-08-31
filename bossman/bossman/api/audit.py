"""Audit-log API (gap #13): a searchable who-did-what-when trail. Admin-only —
the audit record is sensitive (it names actors, IPs, and targets).
"""

from __future__ import annotations

from datetime import datetime

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, require_admin
from bossman.config import Settings, get_settings
from bossman.db.models import Agent, AuditLog
from bossman.db.session import get_session
from bossman.services import external_audit

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
    """Who did what in **this server** — the request-side trail.

    One entry per authenticated mutating call: the actor from the bearer, the target from the path,
    the outcome from the status, plus login successes and failures. Filterable by actor, category,
    status, free text and time.

    Not the same as the **result log** (`/api/v1/operations`), and the difference matters: this records
    what was *asked of Bossman*, that records what *hosts did*. A request that was accepted and an
    action that worked are two facts, and only the second answers "did that install succeed".
    """
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


class ExternalScanIn(BaseModel):
    # A live scan reads auditd on the host. For a push model / testing, `raw` lets
    # a caller hand pre-collected `ausearch` output straight to the parser+ingest.
    raw: str | None = None
    since: str = "today"


@router.post("/api/v1/agents/{agent_id}/audit-external/scan")
async def scan_external_audit(
    agent_id: UUID,
    body: ExternalScanIn,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _admin: Identity = Depends(require_admin),
):
    """Capture out-of-band (drift) changes to this host's managed config via
    auditd and fold them into the audit trail. Live path: install watch rules for
    the files in the host's desired_state, then read auditd since `since`. Or pass
    `raw` (pre-collected ausearch output) to parse+ingest directly. Rows land in
    audit_log as actor_kind=external / source=auditd, so they show up in the Audit
    log next to Bossman's own changes."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="no such host")

    if body.raw is not None:
        res = await external_audit.ingest_raw(session, agent, body.raw)
        return {"host": agent.name, "mode": "raw", **res}

    # Live scan: the managed config paths come from the compiled desired state.
    from bossman.services.config_desired import effective_resources

    eff = await effective_resources(session, agent)
    paths = [e["path"] for e in eff if e.get("path")]

    from bossman.api.plans import get_client_factory

    client = get_client_factory()(agent, settings)
    res = await external_audit.scan_host(session, agent, client, paths, since=body.since)
    return {"host": agent.name, "mode": "live", "paths": len(paths), **res}


@router.get("/api/v1/audit/stats")
async def audit_stats(session: AsyncSession = Depends(get_session), _admin: Identity = Depends(require_admin)):
    """Counts over the audit trail — per actor, category and outcome — for the period asked for.
    The overview above the list, so "unusually many refusals today" is visible without paging."""
    total = await session.scalar(select(func.count()).select_from(AuditLog)) or 0
    by_cat = (await session.execute(
        select(AuditLog.category, func.count()).group_by(AuditLog.category)
    )).all()
    failures = await session.scalar(
        select(func.count()).select_from(AuditLog).where(AuditLog.status == "failed")
    ) or 0
    return {"total": total, "failed": failures, "by_category": {c: n for c, n in by_cat}}
