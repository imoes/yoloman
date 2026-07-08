"""Desired-state reconciler (Block L4) — the controller half of the
Kubernetes-style reconcile loop (see docs/policy-orchestration-architecture.md
§6–§8). A policy/rule/OU/link change enqueues a transactional-outbox event
(same DB transaction as the change, so a change is never lost); a background
worker drains the outbox, recompiles the affected hosts' desired state
(services/compiler), and enqueues a per-(agent, generation) delivery the
agent then PULLs and ACKs. LISTEN/NOTIFY is only a wake-up optimization —
the durable truth is the outbox + compiled_host_state tables; nothing here
mutates a real host.

Framework-free, like services/poller.py / services/monitoring.py.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import AgentConfigDelivery, ControllerOutbox, PolicyEvent
from bossman.services.compiler import compile_host_desired_state

# Retry backoff: attempt n waits min(n*30s, 5min); after this many attempts a
# poison event is parked as 'failed' (dead letter) rather than looping forever.
_MAX_ATTEMPTS = 5
_MAX_BACKOFF = timedelta(minutes=5)


async def enqueue_policy_event(
    session: AsyncSession, tenant_id: UUID, kind: str, *, agent_ids: list[UUID] | None = None, scope: str | None = None
) -> None:
    """Transactional outbox: write a PolicyEvent + a pending ControllerOutbox
    row in the caller's transaction (the caller owns the commit, so the change
    and its event commit atomically). Pass the concrete affected agent_ids
    when known (the cheap, precise path); pass scope='tenant' for a change
    whose blast radius is the whole tenant (e.g. a global rule)."""
    payload: dict = {}
    if agent_ids is not None:
        payload["agent_ids"] = [str(a) for a in agent_ids]
    if scope is not None:
        payload["scope"] = scope
    event = PolicyEvent(tenant_id=tenant_id, kind=kind, payload=payload)
    session.add(event)
    await session.flush()  # need event.id for the outbox FK
    session.add(ControllerOutbox(tenant_id=tenant_id, event_id=event.id, status="pending"))
    await session.flush()


async def _enqueue_delivery(session: AsyncSession, tenant_id: UUID, agent_id: UUID, generation: int, config_hash: str) -> bool:
    """Idempotent per (agent, generation): insert a pending delivery unless
    one already exists. Returns True if a new delivery row was created."""
    existing = await session.scalar(
        select(AgentConfigDelivery).where(
            AgentConfigDelivery.agent_id == agent_id, AgentConfigDelivery.generation == generation
        )
    )
    if existing is not None:
        return False
    session.add(
        AgentConfigDelivery(
            tenant_id=tenant_id, agent_id=agent_id, generation=generation, config_hash=config_hash, status="pending"
        )
    )
    return True


@dataclass
class ReconcileStats:
    last_run_at: datetime | None = None
    processed: int = 0
    recompiled: int = 0
    delivered: int = 0
    failed: int = 0


async def process_outbox_once(session: AsyncSession, batch: int = 50) -> ReconcileStats:
    """Drain up to `batch` ready outbox rows: recompile each event's affected
    hosts and enqueue deliveries for the ones whose generation changed. Uses
    FOR UPDATE SKIP LOCKED so multiple workers never process the same row.
    Commits per row so partial progress survives a crash."""
    stats = ReconcileStats(last_run_at=datetime.now(timezone.utc))
    now = datetime.now(timezone.utc)
    rows = (
        await session.scalars(
            select(ControllerOutbox)
            .where(ControllerOutbox.status == "pending", ControllerOutbox.available_at <= now)
            .order_by(ControllerOutbox.available_at)
            .limit(batch)
            .with_for_update(skip_locked=True)
        )
    ).all()

    for row in rows:
        try:
            event = await session.get(PolicyEvent, row.event_id)
            if event is None:
                row.status = "done"
                row.processed_at = datetime.now(timezone.utc)
                await session.commit()
                stats.processed += 1
                continue

            agent_ids = await _affected_from_event(session, event)
            for agent_id in agent_ids:
                result = await compile_host_desired_state(session, agent_id)
                if result is not None and result.changed:
                    stats.recompiled += 1
                    if await _enqueue_delivery(session, event.tenant_id, agent_id, result.generation, result.config_hash):
                        stats.delivered += 1
            row.status = "done"
            row.processed_at = datetime.now(timezone.utc)
            await session.commit()
            stats.processed += 1
        except Exception as exc:  # noqa: BLE001 — one poison event must not stall the queue
            await session.rollback()
            fresh = await session.get(ControllerOutbox, row.id)
            if fresh is None:
                continue
            fresh.attempts += 1
            fresh.last_error = str(exc)[:2000]
            if fresh.attempts >= _MAX_ATTEMPTS:
                fresh.status = "failed"  # dead letter
                stats.failed += 1
            else:
                backoff = min(fresh.attempts * timedelta(seconds=30), _MAX_BACKOFF)
                fresh.available_at = datetime.now(timezone.utc) + backoff
            await session.commit()
    return stats


async def _affected_from_event(session: AsyncSession, event: PolicyEvent) -> list[UUID]:
    """The hosts an event touches: the explicit agent_ids the enqueuer
    recorded, or (scope='tenant') a full-tenant recompile."""
    payload = event.payload or {}
    if payload.get("agent_ids"):
        return [UUID(a) for a in payload["agent_ids"]]
    if payload.get("scope") == "tenant":
        # compile_tenant handles the recompile + returns a count; but we need
        # the ids to enqueue deliveries, so recompile happens in the caller.
        from bossman.db.models import Agent

        rows = (await session.scalars(select(Agent.id).where(Agent.tenant_id == event.tenant_id))).all()
        return list(rows)
    return []


async def reconciler_loop(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    stop_event,
    stats: ReconcileStats | None = None,
) -> None:
    """Background worker (mirrors services/poller.poller_loop): drains the
    outbox every reconcile_interval_seconds. Gated by settings.reconcile_enabled
    (disabled in the test suite, like the poller/housekeeping loops)."""
    import asyncio

    while not stop_event.is_set():
        if settings.reconcile_enabled:
            try:
                async with session_factory() as session:
                    run = await process_outbox_once(session)
                if stats is not None:
                    stats.last_run_at = run.last_run_at
                    stats.processed += run.processed
                    stats.recompiled += run.recompiled
                    stats.delivered += run.delivered
                    stats.failed += run.failed
            except Exception:  # noqa: BLE001 — never let the loop die
                pass
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=settings.reconcile_interval_seconds)
        except (asyncio.TimeoutError, TimeoutError):
            pass


__all__ = ["enqueue_policy_event", "process_outbox_once", "reconciler_loop", "ReconcileStats"]
