"""Notification rules CRUD + the notification log (Block H8). Auth-gated
like the rest of the REST surface. Rules decide who is told (email/webhook)
on a confirmed problem/recovery; the log records every send (sent|failed).
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.api.etag import check_if_match, compute_version
from bossman.db.models import Notification, NotificationRule, OrchestrationPlan, OUNode, TimePeriod
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
    # L4: only notify while this time period is active. None = always, which is what
    # every rule meant before time periods existed.
    time_period_id: UUID | None = None
    # The shared rule-conditions object (services/rule_conditions) — the same shape CheckRule and
    # ConfigPolicy carry, and what the UI's "Applies to" control writes. {} = no condition, so a rule
    # created without it behaves exactly as before. ANDed with tag_filter, which stays for the rules
    # that already use it.
    conditions: dict = Field(default_factory=dict)


class NotificationRuleOut(NotificationRuleIn):
    id: UUID
    created_at: datetime
    # A3: this object's version. Send it back in If-Match on PUT and a concurrent edit
    # becomes a 412 instead of a silent overwrite. In the payload rather than only in an
    # ETag header because these are collection endpoints — see api/etag.py.
    version: str = ""

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
            conditions=r.conditions or {},
            ou_id=r.ou_id,
            enforced=r.enforced,
            link_order=r.link_order,
            scope_type=r.scope_type,
            scope_value=r.scope_value,
            scope_service_name=r.scope_service_name,
            scope_plan_id=r.scope_plan_id,
            time_period_id=r.time_period_id,
        )

    def with_version(self) -> "NotificationRuleOut":
        self.version = compute_version(self)
        return self


async def _validate(body: NotificationRuleIn, session: AsyncSession) -> None:
    if body.channel not in _CHANNELS:
        raise HTTPException(status_code=422, detail=f"channel must be one of {'|'.join(_CHANNELS)}")
    if body.min_state not in _STATES:
        raise HTTPException(status_code=422, detail=f"min_state must be one of {'|'.join(_STATES)}")
    if not body.target.strip():
        raise HTTPException(status_code=422, detail="target is required")
    if body.ou_id is not None and await session.get(OUNode, body.ou_id) is None:
        raise HTTPException(status_code=422, detail=f"no such OU {body.ou_id}")
    if body.time_period_id is not None and await session.get(TimePeriod, body.time_period_id) is None:
        raise HTTPException(status_code=422, detail=f"no such time period {body.time_period_id}")
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
    """Every notification rule: who gets told about what, and after how long.

    A rule binds a scope (global, OU, group, host) and an optional check filter to a **channel** and
    a target, with the escalation chain that follows if nobody acknowledges. Like check rules, these
    are the *intension* — a rule can exist while nothing has ever matched it.
    """
    rules = (await session.scalars(select(NotificationRule).order_by(NotificationRule.created_at.desc()))).all()
    return [NotificationRuleOut.from_model(r).with_version() for r in rules]


@router.post("/api/v1/notification-rules", response_model=NotificationRuleOut)
async def create_notification_rule(
    body: NotificationRuleIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> NotificationRuleOut:
    """Create a notification rule.

    What is checked, each with its reason in the message: the `channel` is one of the known senders,
    `min_state` is a real state, `target` is not empty, a referenced OU or time period exists, and a
    scope carries its required companion field (an `ou` scope needs an `ou_id`). References are
    resolved **now** rather than when an alarm fires, which is the worst moment to learn that an OU
    was renamed away.

    What is NOT checked: whether `target` suits `channel`. They are validated separately, so an email
    address in a webhook rule is accepted here and fails at dispatch — visible in the notification
    log rather than at the moment of the mistake.

    `escalate_after_minutes` puts the chain on the rule itself, so "who is told next, and when" reads
    out of one row instead of a second object.

    Nothing is sent by creating a rule: the dispatcher acts on state changes, and a rule that matches
    nothing today may match tomorrow.
    """
    await _validate(body, session)
    rule = NotificationRule(**body.model_dump())
    session.add(rule)
    await session.commit()
    return NotificationRuleOut.from_model(rule).with_version()


@router.put("/api/v1/notification-rules/{rule_id}", response_model=NotificationRuleOut)
async def update_notification_rule(
    rule_id: UUID,
    body: NotificationRuleIn,
    request: Request,
    response: Response,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> NotificationRuleOut:
    """Replace a notification rule wholesale — an omitted field is cleared, not kept.

    Honours `If-Match` with the `version` from a previous read (**412** when stale). Use PATCH for a
    partial edit.
    """
    rule = await session.get(NotificationRule, rule_id)
    if rule is None:
        raise HTTPException(status_code=404, detail=f"no such notification rule {rule_id}")
    # A3: before writing, make sure the caller's copy is still current.
    check_if_match(request, NotificationRuleOut.from_model(rule).with_version().version)
    await _validate(body, session)
    for field, value in body.model_dump().items():
        setattr(rule, field, value)
    await session.commit()
    out = NotificationRuleOut.from_model(rule).with_version()
    response.headers["ETag"] = f'"{out.version}"'
    return out


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
    rule_id: UUID, body: NotificationRulePatch, request: Request,
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> NotificationRuleOut:
    """Change individual fields of a notification rule; anything you omit stays as it is.

    `If-Match` is honoured here as on PUT — a stale `version` is refused with **412**, and omitting
    the header skips the check. It was enforced on PUT and not here, and a partial edit is precisely
    where two people changing different fields both assume they are safe.
    """
    rule = await session.get(NotificationRule, rule_id)
    if rule is None:
        raise HTTPException(status_code=404, detail=f"no such notification rule {rule_id}")
    check_if_match(request, NotificationRuleOut.from_model(rule).with_version().version)
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
    return NotificationRuleOut.from_model(rule).with_version()


@router.delete("/api/v1/notification-rules/{rule_id}", status_code=204)
async def delete_notification_rule(
    rule_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    """Delete a notification rule.

    Notifications it already sent stay in the log: `notifications.rule_id` is `ON DELETE SET NULL`
    (verified against the live schema), so each message keeps its channel, target and outcome and
    **loses the pointer to the rule that caused it**. The record of who was told what must survive the
    rule; the explanation of *why* does not survive this call. To keep both, disable the rule instead
    of deleting it.
    """
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
    """What was actually sent: the notification log.

    The *extension* to the rules above — one entry per dispatched message, with its channel, target
    and outcome. This is where "did anyone get told" is answered, and it is deliberately separate
    from the rules: a rule that exists proves nothing about a message that arrived.
    """
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
