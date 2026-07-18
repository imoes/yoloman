"""Notifications (Block H8): decide who to tell when a service has a
confirmed (hard) problem or recovery, and send it by email or webhook.

Framework-free like the rest of services/ so the poller can call it. The
trigger is H7's *hard* state change (soft blips never notify); dispatch
additionally suppresses acknowledged / in-downtime / flapping services —
"we already know, don't page anyone". Sends are logged to `notifications`
(sent|failed) so there's an audit trail and failures are visible.
"""

from __future__ import annotations

import smtplib
from dataclasses import dataclass, field
from email.message import EmailMessage

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import Agent, CheckRule, Notification, NotificationRule, Service
from bossman.services.scope import HostCtx, Scope, ServiceCtx, scope_covers

# Severity ordering for the min_state floor.
_SEVERITY = {"OK": 0, "WARN": 1, "UNKNOWN": 2, "CRIT": 3}


@dataclass
class NotifyEvent:
    """A pending notification produced by the state machine: one service's
    confirmed hard transition. `event` is 'problem' (→ non-OK) or
    'recovery' (→ OK)."""

    agent_name: str
    service_name: str
    state: str
    event: str
    output: str
    # Block K7: the host's tags at the moment of this event, for
    # NotificationRule.tag_filter matching.
    agent_tags: dict = field(default_factory=dict)


def tags_match(tag_filter: dict | None, agent_tags: dict) -> bool:
    """Block K7: does agent_tags satisfy tag_filter? Every key in
    tag_filter must exist on the host; a name-only entry (empty string
    value) matches any value for that key, a name:value entry requires an
    exact match. NULL/empty filter always matches (no tag condition)."""
    if not tag_filter:
        return True
    for key, value in tag_filter.items():
        agent_value = agent_tags.get(key)
        if agent_value is None:
            return False
        if value and agent_value != value:
            return False
    return True


def rule_matches(rule: NotificationRule, ev: NotifyEvent) -> bool:
    """Does this rule want to be told about this event?"""
    if not rule.enabled:
        return False
    if ev.event == "problem" and not rule.on_problem:
        return False
    if ev.event == "recovery" and not rule.on_recovery:
        return False
    # Recoveries ignore the severity floor (a recovery is always OK); a
    # problem must meet the min_state severity.
    if ev.event == "problem" and _SEVERITY.get(ev.state, 0) < _SEVERITY.get(rule.min_state, 1):
        return False
    if rule.host_filter and rule.host_filter not in ev.agent_name:
        return False
    if rule.service_filter and rule.service_filter not in ev.service_name:
        return False
    if not tags_match(rule.tag_filter, ev.agent_tags):
        return False
    return True


def render(ev: NotifyEvent) -> tuple[str, str]:
    """Subject + plain-text body for one event."""
    verb = "RECOVERED" if ev.event == "recovery" else f"{ev.state} PROBLEM"
    subject = f"[bossman] {verb}: {ev.service_name} on {ev.agent_name}"
    body = (
        f"Host:    {ev.agent_name}\n"
        f"Service: {ev.service_name}\n"
        f"State:   {ev.state}\n"
        f"Event:   {ev.event}\n"
        f"Output:  {ev.output}\n"
    )
    return subject, body


def send_email(settings: Settings, to: str, subject: str, body: str) -> None:
    """Sends via the configured SMTP server. Raises on failure (caller
    logs it). `to` may be a comma-separated list."""
    if not settings.smtp_host:
        raise RuntimeError("no smtp_host configured")
    msg = EmailMessage()
    msg["From"] = settings.smtp_from
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(body)
    with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=settings.notify_timeout_seconds) as smtp:
        if settings.smtp_use_tls:
            smtp.starttls()
        if settings.smtp_user:
            smtp.login(settings.smtp_user, settings.smtp_password)
        smtp.send_message(msg)


def send_webhook(settings: Settings, url: str, ev: NotifyEvent, subject: str, body: str) -> None:
    """POSTs a JSON payload to the rule's webhook URL. Raises on non-2xx."""
    payload = {
        "text": subject,
        "host": ev.agent_name,
        "service": ev.service_name,
        "state": ev.state,
        "event": ev.event,
        "output": ev.output,
        "body": body,
    }
    with httpx.Client(timeout=settings.notify_timeout_seconds) as client:
        resp = client.post(url, json=payload)
        resp.raise_for_status()


def _emoji(ev: "NotifyEvent") -> str:
    if ev.event == "recovery":
        return "✅"
    return {"CRIT": "🔴", "WARN": "🟡", "UNKNOWN": "⚪"}.get(ev.state, "🔔")


def send_chat(settings: Settings, channel: str, target: str, ev: "NotifyEvent", subject: str, body: str) -> None:
    """Send to a chat/paging channel. `target` is the channel-specific address:
      slack/teams/discord → the incoming-webhook URL
      telegram            → "<bot_token>:<chat_id>"
      pagerduty           → the Events API v2 routing key
    Each maps our event onto the provider's minimal payload. Raises on non-2xx."""
    text = f"{_emoji(ev)} {subject}\n{ev.agent_name} / {ev.service_name}: {ev.output}".strip()
    with httpx.Client(timeout=settings.notify_timeout_seconds) as client:
        if channel == "slack":
            resp = client.post(target, json={"text": text})
        elif channel == "discord":
            resp = client.post(target, json={"content": text[:1900]})
        elif channel == "teams":
            # Legacy MessageCard (Office365 connector) — widest compatibility.
            color = {"CRIT": "D93F3C", "WARN": "E0A030", "UNKNOWN": "888888"}.get(ev.state, "2E7D32")
            resp = client.post(target, json={
                "@type": "MessageCard", "@context": "http://schema.org/extensions",
                "themeColor": color, "summary": subject, "title": subject,
                "text": f"**{ev.agent_name} / {ev.service_name}**\n\n{ev.output}",
            })
        elif channel == "telegram":
            token, _, chat_id = target.partition(":")
            if not token or not chat_id:
                raise RuntimeError("telegram target must be '<bot_token>:<chat_id>'")
            resp = client.post(f"https://api.telegram.org/bot{token}/sendMessage",
                               json={"chat_id": chat_id, "text": text})
        elif channel == "pagerduty":
            # Events API v2: a problem triggers, a recovery resolves. Dedup key
            # ties the resolve to the trigger (one incident per host+service).
            action = "resolve" if ev.event == "recovery" else "trigger"
            sev = {"CRIT": "critical", "WARN": "warning", "UNKNOWN": "warning"}.get(ev.state, "error")
            resp = client.post("https://events.pagerduty.com/v2/enqueue", json={
                "routing_key": target, "event_action": action,
                "dedup_key": f"{ev.agent_name}/{ev.service_name}",
                "payload": {"summary": subject, "source": ev.agent_name,
                            "severity": sev, "component": ev.service_name, "custom_details": {"output": ev.output}},
            })
        else:
            raise RuntimeError(f"unknown chat channel {channel!r}")
        resp.raise_for_status()


# Chat/paging channels routed through send_chat (vs email/webhook, which have
# their own senders).
_CHAT_CHANNELS = frozenset({"slack", "teams", "telegram", "pagerduty", "discord"})

# Injectable senders (tests pass fakes; production uses the real ones).
EmailSender = None
WebhookSender = None


def _rule_scope(rule: NotificationRule) -> Scope:
    """Read a rule's scope columns into the shared Scope value."""
    return Scope(
        scope_type=rule.scope_type,
        ou_id=str(rule.ou_id) if rule.ou_id else None,
        value=rule.scope_value,
        service_name=rule.scope_service_name,
        plan_id=str(rule.scope_plan_id) if rule.scope_plan_id else None,
    )


async def _event_context(
    session: AsyncSession, ev: NotifyEvent, rules: list[NotificationRule]
) -> tuple[HostCtx, ServiceCtx]:
    """Resolve the host (groups + OU ancestry) and service (policy
    membership) context for one event — once per dispatch. Policy membership
    (the plans assigned to this host) is only computed when some rule is
    actually policy-scoped, since it's the most expensive lookup."""
    # Lazy imports: compiler pulls in the ORM/gpo stack; keep it off module
    # import to mirror collect_and_dispatch's own cycle-avoidance.
    from bossman.services.compiler import resolve_orchestration_assignments, resolve_ou_ancestry

    agent = await session.scalar(select(Agent).where(Agent.name == ev.agent_name))
    groups = list(agent.groups or []) if agent is not None else []
    ou_ids: frozenset[str] = frozenset()
    if agent is not None:
        ancestry = await resolve_ou_ancestry(session, agent.ou_id)
        ou_ids = frozenset(str(n.id) for n in ancestry)
    host_ctx = HostCtx(name=ev.agent_name, groups=groups, ou_ids=ou_ids)

    policy_ids: frozenset[str] = frozenset()
    if agent is not None and any(r.scope_type == "policy" for r in rules):
        assignments = await resolve_orchestration_assignments(session, agent)
        policy_ids = frozenset(str(a.plan_id) for a in assignments)
    return host_ctx, ServiceCtx(service_name=ev.service_name, policy_ids=policy_ids)


def _send_rule(settings: Settings, rule: NotificationRule, ev: NotifyEvent, subject: str, body: str,
               email_sender, webhook_sender, chat_sender) -> tuple[str, str | None]:
    """Send one rule's notification; returns (status, error). Never raises."""
    try:
        if rule.channel == "email":
            email_sender(settings, rule.target, subject, body)
        elif rule.channel == "webhook":
            webhook_sender(settings, rule.target, ev, subject, body)
        elif rule.channel in _CHAT_CHANNELS:
            chat_sender(settings, rule.channel, rule.target, ev, subject, body)
        else:
            return "failed", f"unknown channel {rule.channel!r}"
        return "sent", None
    except Exception as exc:  # noqa: BLE001 — any send failure is logged, never propagated
        return "failed", str(exc)[:2000]


async def dispatch(
    session: AsyncSession,
    settings: Settings,
    ev: NotifyEvent,
    *,
    email_sender=send_email,
    webhook_sender=send_webhook,
    chat_sender=send_chat,
) -> list[Notification]:
    """Evaluates every notification rule against one event, sends to each
    matching rule's channel, and logs the outcome. Never raises — a broken
    channel is recorded as a failed Notification, not propagated (one bad
    rule must not stall the poller or hide other rules). Returns the log
    rows created. Suppression (ack/downtime/flapping) is the caller's job:
    dispatch is only called for events that should actually go out."""
    if not settings.notifications_enabled:
        return []
    rules = (await session.scalars(select(NotificationRule).where(NotificationRule.enabled.is_(True)))).all()
    if not rules:
        return []

    # Block N1: resolve the event's host + service context ONCE, then match
    # each rule's scope against it (additive — every covering rule fires).
    # This is also what finally makes ou/host/service/policy scope actually
    # apply at dispatch (the scope columns were previously ignored).
    host_ctx, svc_ctx = await _event_context(session, ev, rules)

    subject, body = render(ev)
    logs: list[Notification] = []
    for rule in rules:
        # Escalation rules (escalate_after_minutes set) do NOT fire on the
        # immediate state-change event — dispatch_escalations fires them later,
        # once the problem is still unacked past their delay.
        if rule.escalate_after_minutes:
            continue
        if not rule_matches(rule, ev):
            continue
        if not scope_covers(_rule_scope(rule), host_ctx, svc_ctx):
            continue
        status, error = _send_rule(settings, rule, ev, subject, body, email_sender, webhook_sender, chat_sender)
        note = Notification(
            rule_id=rule.id,
            agent_name=ev.agent_name,
            service_name=ev.service_name,
            event=ev.event,
            state=ev.state,
            channel=rule.channel,
            target=rule.target,
            status=status,
            error=error,
        )
        session.add(note)
        logs.append(note)
    return logs


async def _depends_on_active_problem(session: AsyncSession, svc: Service) -> bool:
    """Block K8: True if svc's CheckRule declares a dependency
    (depends_on_service_name) on another service, same agent, that is
    itself currently a confirmed (hard) non-OK problem — the root-cause
    already covers this symptom, so it shouldn't page separately."""
    if svc.rule_id is None:
        return False
    rule = await session.get(CheckRule, svc.rule_id)
    if rule is None or not rule.depends_on_service_name:
        return False
    dep = await session.scalar(
        select(Service).where(Service.agent_id == svc.agent_id, Service.name == rule.depends_on_service_name)
    )
    return dep is not None and dep.state != "OK" and dep.state_type == "hard"


async def collect_and_dispatch(session: AsyncSession, settings: Settings, services: list[Service], **senders) -> int:
    """Given the services an evaluation cycle just touched, dispatch a
    notification for each that had a confirmed hard change AND isn't
    suppressed (acknowledged / in-downtime / flapping). Reads the transient
    `_notify_event` the state machine stamped (see monitoring._upsert_
    service_state). Returns the number of events dispatched. Downtime is
    checked via the same is_in_downtime the problems view uses."""
    from bossman.services.monitoring import is_in_downtime  # local import: avoid a cycle
    from datetime import datetime, timezone

    now = datetime.now(timezone.utc)
    dispatched = 0
    for svc in services:
        event = getattr(svc, "_notify_event", None)
        if not event:
            continue
        # Suppress noise: flapping, or (for a problem) an ack, or a downtime.
        if svc.is_flapping:
            continue
        if event == "problem" and svc.acknowledged:
            continue
        if await is_in_downtime(session, svc.agent_id, svc.name, now):
            continue
        # Block K8 (trigger dependencies): a symptom problem doesn't page
        # anyone while its declared root-cause service is already a
        # confirmed (hard) problem on the same host.
        if event == "problem" and await _depends_on_active_problem(session, svc):
            continue
        # agent_name/tags aren't on the Service row; the state machine stamps them too.
        agent_name = getattr(svc, "_notify_agent_name", "")
        agent_tags = getattr(svc, "_notify_agent_tags", {})
        ev = NotifyEvent(
            agent_name=agent_name,
            service_name=svc.name,
            state=svc.state,
            event=event,
            output=svc.output or "",
            agent_tags=agent_tags,
        )
        await dispatch(session, settings, ev, **senders)
        dispatched += 1
    return dispatched


async def dispatch_escalations(
    session: AsyncSession, settings: Settings, *,
    email_sender=send_email, webhook_sender=send_webhook, chat_sender=send_chat,
) -> int:
    """On-call escalation: for every service that is a confirmed (hard) non-OK
    problem, still unacknowledged and not in downtime, fire any escalation rule
    (escalate_after_minutes set) whose delay has elapsed since the problem went
    hard AND that hasn't already fired for THIS episode. Called once per poll
    cycle. Dedup: a rule fires at most once per (agent, service, episode) — a
    Notification row for it after last_state_change means "already escalated".
    Returns the count sent."""
    if not settings.notifications_enabled:
        return 0
    from datetime import datetime, timezone
    from bossman.services.monitoring import is_in_downtime

    esc_rules = (await session.scalars(
        select(NotificationRule).where(
            NotificationRule.enabled.is_(True), NotificationRule.escalate_after_minutes.isnot(None)
        )
    )).all()
    if not esc_rules:
        return 0

    now = datetime.now(timezone.utc)
    # Candidate problems: hard, non-OK, unacked.
    problems = (await session.scalars(
        select(Service).where(
            Service.state != "OK", Service.state_type == "hard", Service.acknowledged.is_(False),
        )
    )).all()
    if not problems:
        return 0

    agents = {a.id: a for a in (await session.scalars(select(Agent))).all()}
    sent = 0
    for svc in problems:
        agent = agents.get(svc.agent_id)
        if agent is None:
            continue
        if await is_in_downtime(session, svc.agent_id, svc.name, now):
            continue
        mins_open = (now - svc.last_state_change).total_seconds() / 60.0
        ev = NotifyEvent(agent_name=agent.name, service_name=svc.name, state=svc.state,
                         event="problem", output=svc.output or "", agent_tags=agent.agent_metadata or {})
        host_ctx, svc_ctx = await _event_context(session, ev, esc_rules)
        subject, body = render(ev)
        for rule in esc_rules:
            if mins_open < rule.escalate_after_minutes:
                continue
            if not rule_matches(rule, ev) or not scope_covers(_rule_scope(rule), host_ctx, svc_ctx):
                continue
            # Already escalated this episode? (a send for this rule after the
            # problem went hard).
            prior = await session.scalar(
                select(Notification.id).where(
                    Notification.rule_id == rule.id, Notification.agent_name == agent.name,
                    Notification.service_name == svc.name, Notification.event == "problem",
                    Notification.created_at >= svc.last_state_change,
                ).limit(1)
            )
            if prior is not None:
                continue
            status, error = _send_rule(settings, rule, ev, subject, body, email_sender, webhook_sender, chat_sender)
            session.add(Notification(
                rule_id=rule.id, agent_name=agent.name, service_name=svc.name, event="problem",
                state=svc.state, channel=rule.channel, target=rule.target, status=status, error=error,
            ))
            sent += 1
    return sent
