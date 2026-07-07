"""Notification rules CRUD + the notification log (Block H8). Auth-gated
like the rest of the REST surface. Rules decide who is told (email/webhook)
on a confirmed problem/recovery; the log records every send (sent|failed).
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import Notification, NotificationRule
from bossman.db.session import get_session

router = APIRouter()

_CHANNELS = ("email", "webhook")
_STATES = ("WARN", "CRIT", "UNKNOWN")


class NotificationRuleIn(BaseModel):
    name: str
    enabled: bool = True
    on_problem: bool = True
    on_recovery: bool = True
    min_state: str = "WARN"
    host_filter: str | None = None
    service_filter: str | None = None
    channel: str
    target: str
    # Block K7: subset match against the problem host's Agent.tags — every
    # key:value pair here must be present (empty-string value = name-only,
    # matches any value for that key). None = no tag condition.
    tag_filter: dict[str, str] | None = None


class NotificationRuleOut(NotificationRuleIn):
    id: UUID
    created_at: datetime

    @classmethod
    def from_model(cls, r: NotificationRule) -> "NotificationRuleOut":
        return cls(
            id=r.id,
            name=r.name,
            enabled=r.enabled,
            on_problem=r.on_problem,
            on_recovery=r.on_recovery,
            min_state=r.min_state,
            host_filter=r.host_filter,
            service_filter=r.service_filter,
            channel=r.channel,
            target=r.target,
            created_at=r.created_at,
            tag_filter=r.tag_filter,
        )


def _validate(body: NotificationRuleIn) -> None:
    if body.channel not in _CHANNELS:
        raise HTTPException(status_code=422, detail=f"channel must be one of {'|'.join(_CHANNELS)}")
    if body.min_state not in _STATES:
        raise HTTPException(status_code=422, detail=f"min_state must be one of {'|'.join(_STATES)}")
    if not body.target.strip():
        raise HTTPException(status_code=422, detail="target is required")


@router.get("/api/v1/notification-rules", response_model=list[NotificationRuleOut])
async def list_notification_rules(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[NotificationRuleOut]:
    rules = (await session.scalars(select(NotificationRule).order_by(NotificationRule.created_at.desc()))).all()
    return [NotificationRuleOut.from_model(r) for r in rules]


@router.post("/api/v1/notification-rules", response_model=NotificationRuleOut)
async def create_notification_rule(
    body: NotificationRuleIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> NotificationRuleOut:
    _validate(body)
    rule = NotificationRule(**body.model_dump())
    session.add(rule)
    await session.commit()
    return NotificationRuleOut.from_model(rule)


@router.put("/api/v1/notification-rules/{rule_id}", response_model=NotificationRuleOut)
async def update_notification_rule(
    rule_id: UUID, body: NotificationRuleIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> NotificationRuleOut:
    rule = await session.get(NotificationRule, rule_id)
    if rule is None:
        raise HTTPException(status_code=404, detail=f"no such notification rule {rule_id}")
    _validate(body)
    for field, value in body.model_dump().items():
        setattr(rule, field, value)
    await session.commit()
    return NotificationRuleOut.from_model(rule)


@router.delete("/api/v1/notification-rules/{rule_id}", status_code=204)
async def delete_notification_rule(
    rule_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    rule = await session.get(NotificationRule, rule_id)
    if rule is None:
        raise HTTPException(status_code=404, detail=f"no such notification rule {rule_id}")
    await session.delete(rule)
    await session.commit()


class NotificationOut(BaseModel):
    id: UUID
    agent_name: str
    service_name: str
    event: str
    state: str
    channel: str
    target: str
    status: str
    error: str | None
    created_at: datetime


@router.get("/api/v1/notifications", response_model=list[NotificationOut])
async def list_notifications(
    limit: int = Query(100, ge=1, le=1000),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[NotificationOut]:
    rows = (await session.scalars(select(Notification).order_by(Notification.created_at.desc()).limit(limit))).all()
    return [
        NotificationOut(
            id=n.id,
            agent_name=n.agent_name,
            service_name=n.service_name,
            event=n.event,
            state=n.state,
            channel=n.channel,
            target=n.target,
            status=n.status,
            error=n.error,
            created_at=n.created_at,
        )
        for n in rows
    ]
