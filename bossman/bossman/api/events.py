"""Event Console API (gap #2): browse + acknowledge passively-received events
(syslog / SNMP traps). Read-mostly; ingestion is services/event_console.py.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity
from bossman.db.models import Event
from bossman.db.session import get_session

router = APIRouter()

_SEV_NAMES = ["emerg", "alert", "crit", "error", "warning", "notice", "info", "debug"]


class EventOut(BaseModel):
    id: UUID
    received_at: datetime
    kind: str
    source_ip: str
    host_name: str | None
    severity: int
    severity_name: str
    facility: int | None
    app: str | None
    message: str
    acknowledged: bool

    @classmethod
    def of(cls, e: Event) -> "EventOut":
        return cls(
            id=e.id, received_at=e.received_at, kind=e.kind, source_ip=e.source_ip,
            host_name=e.host_name, severity=e.severity,
            severity_name=_SEV_NAMES[e.severity] if 0 <= e.severity < 8 else str(e.severity),
            facility=e.facility, app=e.app, message=e.message, acknowledged=e.acknowledged,
        )


@router.get("/api/v1/events", response_model=list[EventOut])
async def list_events(
    kind: str | None = None,
    host: str | None = None,
    max_severity: int | None = Query(None, description="Only events at or below this syslog severity (0=emerg..7=debug)"),
    unacked: bool = False,
    limit: int = Query(200, le=1000),
    session: AsyncSession = Depends(get_session),
    _i: Identity = Depends(get_current_identity),
):
    """Passively received events: syslog messages and SNMP traps, as they arrived.

    Raw, before they are anything else — an event is not a problem, has no host ACL applied to its
    origin, and may name a device this fleet does not know. Turning one into a service state or an
    action is what event *rules* do.
    """
    stmt = select(Event).order_by(Event.received_at.desc()).limit(limit)
    if kind:
        stmt = stmt.where(Event.kind == kind)
    if host:
        stmt = stmt.where(Event.host_name == host)
    if max_severity is not None:
        stmt = stmt.where(Event.severity <= max_severity)
    if unacked:
        stmt = stmt.where(Event.acknowledged.is_(False))
    rows = (await session.scalars(stmt)).all()
    return [EventOut.of(e) for e in rows]


@router.post("/api/v1/events/{event_id}/ack", response_model=EventOut)
async def ack_event(event_id: UUID, session: AsyncSession = Depends(get_session),
                    _i: Identity = Depends(get_current_identity)):
    """Acknowledge an event: someone has seen it.

    It stays in the console with the acknowledgement recorded, rather than disappearing — an event
    that vanishes when noticed cannot be counted afterwards.
    """
    e = await session.get(Event, event_id)
    if e is None:
        raise HTTPException(404, "no such event")
    e.acknowledged = True
    await session.commit()
    await session.refresh(e)
    return EventOut.of(e)


@router.get("/api/v1/events/stats")
async def event_stats(session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    """Counts for the console header: total, unacked, and unacked at severity
    <= warning (the ones that actually matter)."""
    from sqlalchemy import func

    total = (await session.scalar(select(func.count()).select_from(Event))) or 0
    unacked = (await session.scalar(select(func.count()).select_from(Event).where(Event.acknowledged.is_(False)))) or 0
    urgent = (await session.scalar(
        select(func.count()).select_from(Event).where(Event.acknowledged.is_(False), Event.severity <= 4)
    )) or 0
    return {"total": total, "unacked": unacked, "urgent": urgent}
