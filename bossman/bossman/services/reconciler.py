"""Desired-state reconciler (Block L4) — the controller half of the
Kubernetes-style reconcile loop (see docs/policy-orchestration-architecture.md
§6–§8). A policy/rule/OU/link change enqueues a transactional-outbox event
(same DB transaction as the change, so a change is never lost); a background
worker drains the outbox, recompiles the affected hosts' desired state
(services/compiler), and — for every host whose generation changed — PUSHES
the new desired state to that agent's own POST /api/v1/config/apply over the
existing mTLS channel (services/agent_client). The agent's JSON response is
the ack, recorded as the delivery's status + an AgentAck row.

This is PUSH, not pull: the agent never dials into Bossman, so the firewall
needs a single rule (Bossman -> agent). LISTEN/NOTIFY is only a wake-up
optimization — the durable truth is the outbox + compiled_host_state tables;
a failed push backs off and is retried, it is never lost.

Framework-free, like services/poller.py / services/monitoring.py.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import Agent, AgentAck, AgentConfigDelivery, ControllerOutbox, PolicyEvent
from bossman.services.agent_client import AgentClient, AgentClientError, client_for
from bossman.services.compiler import CompiledState, compile_host_desired_state

# A factory that turns an Agent + Settings into a live client — the real one
# is services.agent_client.client_for; tests inject a fake so no socket is
# opened. Kept as a parameter (not a hard import) purely for testability.
ClientFactory = Callable[[Agent, Settings], AgentClient]

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


async def _delivery_for(session: AsyncSession, agent: Agent, result: CompiledState) -> AgentConfigDelivery:
    """The delivery row for this (agent, generation), created 'pending' if it
    doesn't exist yet — idempotent on the (agent_id, generation) unique
    constraint, so a retried push reuses the same row."""
    delivery = await session.scalar(
        select(AgentConfigDelivery).where(
            AgentConfigDelivery.agent_id == agent.id, AgentConfigDelivery.generation == result.generation
        )
    )
    if delivery is None:
        delivery = AgentConfigDelivery(
            tenant_id=agent.tenant_id,
            agent_id=agent.id,
            generation=result.generation,
            config_hash=result.config_hash,
            status="pending",
        )
        session.add(delivery)
        # Flush so the `attempts` default (0) is materialized — an un-flushed
        # ORM object carries None for default=-only columns, which would make
        # the `delivery.attempts += 1` in _push_to_agent a TypeError.
        await session.flush()
    return delivery


async def _push_to_agent(
    session: AsyncSession, agent: Agent, result: CompiledState, client_factory: ClientFactory, settings: Settings
) -> bool:
    """PUSH one changed generation to the agent's POST /api/v1/config/apply and
    record the outcome. On the agent's 200 response the delivery flips to
    'acked' + an AgentAck('ack') is written; on any transport/HTTP error the
    delivery flips to 'nacked' (or 'failed' after too many attempts) + an
    AgentAck('nack') carrying the error. Returns True iff the agent applied it.

    Never raises — a single unreachable agent must not stall the outbox; the
    delivery row's status/attempts drive any later retry."""
    delivery = await _delivery_for(session, agent, result)
    delivery.attempts += 1
    delivery.updated_at = datetime.now(timezone.utc)
    client = client_factory(agent, settings)
    try:
        resp = await client.apply_config(result.generation, result.config_hash, result.state)
    except AgentClientError as exc:
        delivery.status = "failed" if delivery.attempts >= _MAX_ATTEMPTS else "nacked"
        delivery.last_error = str(exc)[:2000]
        session.add(
            AgentAck(
                tenant_id=agent.tenant_id,
                agent_id=agent.id,
                generation=result.generation,
                result="nack",
                detail={"error": str(exc)[:2000]},
            )
        )
        return False

    delivery.status = "acked"
    delivery.last_error = None
    agent.last_seen_at = datetime.now(timezone.utc)
    session.add(
        AgentAck(
            tenant_id=agent.tenant_id,
            agent_id=agent.id,
            generation=result.generation,
            result="ack",
            detail=resp if isinstance(resp, dict) else {"response": resp},
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


async def process_outbox_once(
    session: AsyncSession,
    settings: Settings,
    batch: int = 50,
    client_factory: ClientFactory = client_for,
) -> ReconcileStats:
    """Drain up to `batch` ready outbox rows: recompile each event's affected
    hosts and PUSH the new desired state to every host whose generation
    changed. Uses FOR UPDATE SKIP LOCKED so multiple workers never process the
    same row. Commits per row so partial progress survives a crash."""
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
                if result is None or not result.changed:
                    continue
                stats.recompiled += 1
                agent = await session.get(Agent, agent_id)
                if agent is None:
                    continue
                if await _push_to_agent(session, agent, result, client_factory, settings):
                    stats.delivered += 1
                else:
                    stats.failed += 1
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
    client_factory: ClientFactory = client_for,
) -> None:
    """Background worker (mirrors services/poller.poller_loop): drains the
    outbox every reconcile_interval_seconds. Gated by settings.reconcile_enabled
    (disabled in the test suite, like the poller/housekeeping loops)."""
    import asyncio

    while not stop_event.is_set():
        if settings.reconcile_enabled:
            try:
                async with session_factory() as session:
                    run = await process_outbox_once(session, settings, client_factory=client_factory)
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


@dataclass
class ConvergeStats:
    last_run_at: datetime | None = None
    checked: int = 0
    pushed: int = 0
    failed: int = 0


async def _last_acked_generation(session: AsyncSession, agent_id: UUID) -> int:
    """The newest generation this agent has actually ACKed (0 if never)."""
    g = await session.scalar(
        select(func.max(AgentConfigDelivery.generation)).where(
            AgentConfigDelivery.agent_id == agent_id, AgentConfigDelivery.status == "acked"
        )
    )
    return int(g or 0)


async def converge_once(
    session: AsyncSession, settings: Settings, *, client_factory: ClientFactory = client_for
) -> ConvergeStats:
    """Convergence sweep (gap #15): the safety net that makes config distribution
    eventually-consistent regardless of what triggered — or failed to trigger — a
    push. For every agent it (re)compiles the desired state and, whenever the
    compiled generation is ahead of what the agent last ACKed, PUSHES it. This
    catches: hosts that were unreachable when the event-driven reconciler fired,
    freshly-enrolled hosts (no delivery yet), and mutations whose endpoint never
    enqueued a PolicyEvent. Idempotent — an up-to-date, acked host is skipped."""
    stats = ConvergeStats(last_run_at=datetime.now(timezone.utc))
    agents = (await session.scalars(select(Agent).where(Agent.address.isnot(None)))).all()
    for agent in agents:
        stats.checked += 1
        try:
            result = await compile_host_desired_state(session, agent.id)
            if result is None:
                continue
            acked = await _last_acked_generation(session, agent.id)
            if result.generation <= acked:
                continue  # host already has (and acked) the current generation
            ok = await _push_to_agent(session, agent, result, client_factory, settings)
            stats.pushed += 1 if ok else 0
            stats.failed += 0 if ok else 1
            await session.commit()
        except Exception:  # noqa: BLE001 — one bad host must not stall the sweep
            await session.rollback()
            stats.failed += 1
    return stats


async def converge_loop(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    stop_event,
    stats: ConvergeStats | None = None,
    client_factory: ClientFactory = client_for,
) -> None:
    """Periodic convergence sweep. Slower cadence than the event-driven
    reconciler (it recompiles every host) — it's the backstop, not the fast
    path. Gated by settings.config_sync_enabled / config_sync_interval_seconds."""
    import asyncio

    if not settings.config_sync_enabled:
        return
    interval = max(60, settings.config_sync_interval_seconds)
    while not stop_event.is_set():
        try:
            async with session_factory() as session:
                run = await converge_once(session, settings, client_factory=client_factory)
            if stats is not None:
                stats.last_run_at = run.last_run_at
                stats.checked += run.checked
                stats.pushed += run.pushed
                stats.failed += run.failed
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            pass
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval)
        except (asyncio.TimeoutError, TimeoutError):
            pass


__all__ = [
    "enqueue_policy_event", "process_outbox_once", "reconciler_loop", "ReconcileStats",
    "converge_once", "converge_loop", "ConvergeStats",
]
