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
from bossman.db.models import Notification, NotificationRule, OrchestrationPlan, OUNode
from bossman.db.session import get_session

router = APIRouter()

_CHANNELS = ("email", "webhook", "slack", "teams", "telegram", "pagerduty", "discord")
_STATES = ("WARN", "CRIT", "UNKNOWN")
_SCOPES = ("global", "ou", "group", "host", "service", "policy")


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
    # On-call escalation: fire only once a hard problem is still unacked this
    # many minutes (None = immediate). A chain = several rules at 0/15/60.
    escalate_after_minutes: int | None = None
    # Block K7: subset match against the problem host's Agent.tags — every
    # key:value pair here must be present (empty-string value = name-only,
    # matches any value for that key). None = no tag condition.
    tag_filter: dict[str, str] | None = None
    # Block L3a: OU binding + GPO precedence. ou_id NULL = global (today's
    # behavior); a value scopes the rule to that OU's subtree.
    ou_id: UUID | None = None
    enforced: bool = False
    link_order: int = 100
    # Block N1: the shared scope model (global|ou|group|host|service|policy).
    # A notification is an additive filter — it fires for every event its
    # scope covers. scope_value = group name (group) or agent (host/service);
    # scope_service_name for service scope; scope_plan_id for policy scope.
    scope_type: str = "global"
    scope_value: str | None = None
    scope_service_name: str | None = None
    scope_plan_id: UUID | None = None


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
            escalate_after_minutes=r.escalate_after_minutes,
            created_at=r.created_at,
            tag_filter=r.tag_filter,
            ou_id=r.ou_id,
            enforced=r.enforced,
            link_order=r.link_order,
            scope_type=r.scope_type,
            scope_value=r.scope_value,
            scope_service_name=r.scope_service_name,
            scope_plan_id=r.scope_plan_id,
        )


async def _validate(body: NotificationRuleIn, session: AsyncSession) -> None:
    if body.channel not in _CHANNELS:
        raise HTTPException(status_code=422, detail=f"channel must be one of {'|'.join(_CHANNELS)}")
    if body.min_state not in _STATES:
        raise HTTPException(status_code=422, detail=f"min_state must be one of {'|'.join(_STATES)}")
    if not body.target.strip():
        raise HTTPException(status_code=422, detail="target is required")
    if body.ou_id is not None and await session.get(OUNode, body.ou_id) is None:
        raise HTTPException(status_code=422, detail=f"no such OU {body.ou_id}")
    # Block N1: validate the scope + its required companion field.
    if body.scope_type not in _SCOPES:
        raise HTTPException(status_code=422, detail=f"scope_type must be one of {'|'.join(_SCOPES)}")
    if body.scope_type == "ou" and body.ou_id is None:
        raise HTTPException(status_code=422, detail="scope_type='ou' requires ou_id")
    if body.scope_type in ("group", "host", "service") and not (body.scope_value or "").strip():
        raise HTTPException(status_code=422, detail=f"scope_type={body.scope_type!r} requires scope_value")
    if body.scope_type == "service" and not (body.scope_service_name or "").strip():
        raise HTTPException(status_code=422, detail="scope_type='service' requires scope_service_name")
    if body.scope_type == "policy":
        if body.scope_plan_id is None:
            raise HTTPException(status_code=422, detail="scope_type='policy' requires scope_plan_id")
        if await session.get(OrchestrationPlan, body.scope_plan_id) is None:
            raise HTTPException(status_code=422, detail=f"no such plan {body.scope_plan_id}")


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
    await _validate(body, session)
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
    await _validate(body, session)
    for field, value in body.model_dump().items():
        setattr(rule, field, value)
    await session.commit()
    return NotificationRuleOut.from_model(rule)


class NotificationRulePatch(BaseModel):
    """Partial GPO-flag update (Block L3a) — the tree console's Enforced /
    Enabled context-menu toggles. `ou_id` re-scopes the rule to another OU
    (the palette drag-to-link gesture, Block L3e)."""

    enforced: bool | None = None
    enabled: bool | None = None
    link_order: int | None = None
    ou_id: UUID | None = None


@router.patch("/api/v1/notification-rules/{rule_id}", response_model=NotificationRuleOut)
async def patch_notification_rule(
    rule_id: UUID, body: NotificationRulePatch, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> NotificationRuleOut:
    rule = await session.get(NotificationRule, rule_id)
    if rule is None:
        raise HTTPException(status_code=404, detail=f"no such notification rule {rule_id}")
    if body.enforced is not None:
        rule.enforced = body.enforced
    if body.enabled is not None:
        rule.enabled = body.enabled
    if body.link_order is not None:
        rule.link_order = body.link_order
    if body.ou_id is not None:
        if await session.get(OUNode, body.ou_id) is None:
            raise HTTPException(status_code=422, detail=f"no such OU {body.ou_id}")
        rule.ou_id = body.ou_id
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
