"""Background metrics + connection-edge poller (see docs/plan.md's
Bossman plan, section B.4): for each enrolled agent, pulls
GET /api/v1/metrics and GET /api/v1/net/connections/dump on an interval,
cursor-based off that agent's own last-successful-pull timestamps (see
Agent.last_metrics_pulled_at/last_edges_pulled_at) so a Bossman restart or
outage doesn't lose data — it just catches up from where it left off on
the next run. Bounded concurrency via asyncio.Semaphore rather than a task
queue (Celery/Redis): comfortably sufficient at this project's targeted
fleet size (~100 hosts).

Framework-free (no FastAPI import) like bossman.services.enrollment, for
the same reason: reachable from the app's background task, a future CLI,
and tests without duplicating logic.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import Agent, HostEdge, Metric
from bossman.services.agent_client import AgentClient, AgentClientError, client_for
from bossman.services.monitoring import evaluate_host, ingest_agent_checks

logger = logging.getLogger(__name__)

ClientFactory = Callable[[Agent, Settings], AgentClient]

_default_client_factory: ClientFactory = client_for


@dataclass
class PollResult:
    agent_id: str
    agent_name: str
    metrics_written: int = 0
    # How many hosts GET /api/v1/hosts/overview reported beyond the polled
    # agent itself — 0 for a standalone/satellite agent, 1+ for a proxy
    # (Selecta) currently relaying one or more satellites (Duppies). See
    # docs/plan.md's monitoring-cockpit ergänzung Block F2.
    satellites_discovered: int = 0
    edges_written: int = 0
    errors: list[str] = field(default_factory=list)


async def _resolve_dst_agent_id(session: AsyncSession, dst_addr: str) -> uuid.UUID | None:
    """Best-effort: an agent's `address` is "host:port" of its own REST
    API, unrelated to whatever port a traced connection actually used —
    so this only matches on the host part. Not guaranteed to resolve
    every edge (an agent might not be enrolled, or reachable under a
    different name/IP than its edges report), which is why HostEdge's
    dst_agent_id column is nullable."""
    return await session.scalar(select(Agent.id).where(Agent.address.like(f"{dst_addr}:%")))


def _disambiguate_colliding_timestamps(rows: list[dict]) -> None:
    """Mutates rows in place. Metric's primary key is (time, agent_id,
    metric) — it deliberately does NOT include `labels`, since the
    original design only ever had to handle one series per metric name.
    Block F1's agent-side sampler changed that: it timestamps every point
    in one sampling tick with the exact same `now` (see
    internal/collect.Sample), so two label-partitioned series of the same
    metric — e.g. disk_used_pct for two different mounts, net_rx_bytes
    for two different interfaces — collide on that primary key and
    ON CONFLICT DO NOTHING silently drops all but one of them. Bossman
    owns this storage constraint (not the agent), so it nudges every
    same-key row after the first forward by 1 microsecond — invisible for
    graphing at any real polling interval, but keeps every label-distinct
    series' data point instead of silently losing it."""
    seen: dict[tuple, int] = {}
    for row in rows:
        key = (row["time"], row["agent_id"], row["metric"])
        count = seen.get(key, 0)
        if count:
            row["time"] = row["time"] + timedelta(microseconds=count)
        seen[key] = count + 1


async def _write_metrics(session: AsyncSession, agent_id: uuid.UUID, metrics: dict) -> int:
    rows = []
    for metric_name, points in metrics.items():
        for point in points:
            rows.append(
                {
                    "time": datetime.fromisoformat(point["timestamp"]),
                    "agent_id": agent_id,
                    "metric": metric_name,
                    "value": point["value"],
                    "labels": point.get("labels") or {},
                }
            )
    if not rows:
        return 0
    # ON CONFLICT DO NOTHING: re-polling an overlapping boundary (the last
    # cursor's exact timestamp can appear in both the previous and the
    # next pull) must not raise on the hypertable's (time, agent_id,
    # metric) primary key.
    _disambiguate_colliding_timestamps(rows)
    stmt = pg_insert(Metric).values(rows).on_conflict_do_nothing(index_elements=["time", "agent_id", "metric"])
    await session.execute(stmt)
    return len(rows)


async def _upsert_edges(session: AsyncSession, agent_id: uuid.UUID, edges: list[dict]) -> int:
    count = 0
    for e in edges:
        dst_agent_id = await _resolve_dst_agent_id(session, e["dst_addr"])
        latency_ns = e.get("latency_ns")
        latency_ms = (latency_ns / 1_000_000) if latency_ns is not None else None

        stmt = pg_insert(HostEdge).values(
            src_agent_id=agent_id,
            src_comm=e["comm"],
            dst_addr=e["dst_addr"],
            dst_port=e["dst_port"],
            dst_agent_id=dst_agent_id,
            event_count=e["event_count"],
            first_seen_at=datetime.fromisoformat(e["first_seen"]),
            last_seen_at=datetime.fromisoformat(e["last_seen"]),
            # Only a single point estimate is available per edge from the
            # agent's dump (not a distribution) — stored as p50, p99 is
            # left NULL until the agent can report percentiles itself.
            latency_ms_p50=latency_ms,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=["src_agent_id", "src_comm", "dst_addr", "dst_port"],
            set_={
                "dst_agent_id": stmt.excluded.dst_agent_id,
                # event_count from the agent is already a lifetime
                # cumulative counter (see internal/store.UpsertEdge on the
                # Go side), not a delta for this poll window — overwrite,
                # don't add.
                "event_count": stmt.excluded.event_count,
                "last_seen_at": stmt.excluded.last_seen_at,
                "latency_ms_p50": stmt.excluded.latency_ms_p50,
            },
        )
        await session.execute(stmt)
        count += 1
    return count


async def _write_snapshot_metrics(
    session: AsyncSession, agent_id: uuid.UUID, sample_time: datetime, metrics: list[dict]
) -> int:
    """Writes GET /api/v1/hosts/overview's flat `metrics` list (one latest
    value per series, no per-point timestamp) as Metric rows, all sharing
    sample_time — an approximation, not a real history (the existing
    GET /api/v1/metrics cursor-pull already covers real history for a
    directly-polled agent), but the only data Bossman ever gets for a
    satellite it cannot reach directly. Same ON CONFLICT DO NOTHING
    dedup as _write_metrics, for the identical reason (overlapping pulls
    can repeat the same (time, agent_id, metric) primary key)."""
    if not metrics:
        return 0
    rows = [
        {"time": sample_time, "agent_id": agent_id, "metric": m["metric"], "value": m["value"], "labels": m.get("labels") or {}}
        for m in metrics
    ]
    _disambiguate_colliding_timestamps(rows)
    stmt = pg_insert(Metric).values(rows).on_conflict_do_nothing(index_elements=["time", "agent_id", "metric"])
    await session.execute(stmt)
    return len(rows)


async def _find_or_create_satellite(session: AsyncSession, name: str, parent_agent_id: uuid.UUID, mode: str) -> Agent:
    """Finds or creates the Agent row for a satellite discovered via a
    proxy's own GET /api/v1/hosts/overview (see docs/plan.md's
    monitoring-cockpit ergänzung Block F2) — the fix for a satellite
    behind a proxy previously being invisible in Bossman entirely (its
    metrics silently merged onto the proxy's own agent row). A satellite
    row's `token`/`address` stay empty: Bossman never polls it directly,
    only ever relays its data through the proxy that already reached it —
    `poll_once`'s own `enrollment_state == "enrolled"` selection would
    otherwise also try to poll it directly and no-op (no address), which
    is harmless but the row's real name (agents.name is unique) must
    already exist before that no-op check runs, so this is called eagerly
    on every proxy poll, not lazily."""
    existing = await session.scalar(select(Agent).where(Agent.name == name))
    if existing is not None:
        if existing.parent_agent_id != parent_agent_id or existing.mode != mode:
            existing.parent_agent_id = parent_agent_id
            existing.mode = mode
        return existing

    satellite = Agent(
        name=name,
        token="",
        mode=mode,
        enrollment_state="enrolled",
        agent_metadata={},
        parent_agent_id=parent_agent_id,
    )
    session.add(satellite)
    await session.flush()
    return satellite


async def _ingest_hosts_overview(session: AsyncSession, agent: Agent, hosts: list[dict]) -> int:
    """Ingests one GET /api/v1/hosts/overview response: the polled
    agent's own entry becomes agent-reported Services (its metrics
    already arrive via the existing full-history /api/v1/metrics pull, so
    only its checks are new information here); every other entry is a
    satellite relayed through this agent (a proxy) — discovered/updated
    as its own Agent row, its latest metrics written, its checks ingested,
    and Bossman's own check_rules evaluated against it exactly like any
    directly-enrolled host. Returns the number of satellite hosts found.
    Best-effort per host: one satellite's failure doesn't stop the rest
    from being ingested.

    The self entry is identified by an empty/absent `parent` field, NOT
    by `host == agent.name`: the Go agent reports its own OS hostname
    (os.Hostname()) as `host`, which need not match whatever name this
    agent was *enrolled* under in Bossman (an operator-chosen, arbitrary
    string — see internal/enroll's --name flag) — matching by name alone
    previously misfiled the proxy's own self entry as a bogus satellite
    of itself whenever the two names differed, confirmed against the real
    running stack before this fix."""
    now = datetime.now(timezone.utc)
    satellite_count = 0

    for host in hosts:
        host_name = host.get("host")
        if not host_name:
            continue

        if not host.get("parent"):
            await ingest_agent_checks(session, agent, host.get("checks") or [])
            continue

        satellite_count += 1
        satellite = await _find_or_create_satellite(session, host_name, agent.id, host.get("mode") or "satellite")
        sample_time = now
        if host.get("last_sample_at"):
            try:
                sample_time = datetime.fromisoformat(host["last_sample_at"].replace("Z", "+00:00"))
            except ValueError:
                pass
        await _write_snapshot_metrics(session, satellite.id, sample_time, host.get("metrics") or [])
        await ingest_agent_checks(session, satellite, host.get("checks") or [])
        satellite.last_seen_at = now
        await evaluate_host(session, satellite)

    return satellite_count


async def poll_agent(
    session_factory: async_sessionmaker[AsyncSession],
    agent_id: uuid.UUID,
    settings: Settings,
    semaphore: asyncio.Semaphore,
    client_factory: ClientFactory = _default_client_factory,
) -> PollResult:
    async with semaphore, session_factory() as session:
        agent = await session.get(Agent, agent_id)
        if agent is None or agent.enrollment_state != "enrolled" or not agent.address:
            return PollResult(agent_id=str(agent_id), agent_name=agent.name if agent else "?")

        result = PollResult(agent_id=str(agent.id), agent_name=agent.name)
        client = client_factory(agent, settings)
        now = datetime.now(timezone.utc)
        reached_agent = False

        try:
            metrics = await client.metrics_dump(agent.last_metrics_pulled_at)
            result.metrics_written = await _write_metrics(session, agent.id, metrics)
            agent.last_metrics_pulled_at = now
            reached_agent = True
        except AgentClientError as exc:
            result.errors.append(f"metrics: {exc}")

        try:
            edges = await client.connections_dump(agent.last_edges_pulled_at)
            result.edges_written = await _upsert_edges(session, agent.id, edges)
            agent.last_edges_pulled_at = now
            reached_agent = True
        except AgentClientError as exc:
            result.errors.append(f"edges: {exc}")

        try:
            hosts = await client.hosts_overview()
            result.satellites_discovered = await _ingest_hosts_overview(session, agent, hosts)
            reached_agent = True
        except AgentClientError as exc:
            result.errors.append(f"hosts_overview: {exc}")

        if reached_agent:
            agent.last_seen_at = now

        # Runs regardless of whether this cycle's metrics pull succeeded —
        # a transient pull failure shouldn't also freeze monitoring state
        # evaluation against whatever value is already stored. Isolated in
        # its own try/except so one host's evaluation bug can't crash the
        # whole poll cycle (mirrors the metrics/edges try/except above).
        try:
            await evaluate_host(session, agent)
        except Exception:
            logger.exception("evaluate_host failed for agent %s", agent.name)

        await session.commit()
        return result


async def poll_once(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    client_factory: ClientFactory = _default_client_factory,
) -> list[PollResult]:
    """Runs one full poll cycle over every enrolled agent, bounded to
    settings.poll_concurrency in flight at a time. client_factory exists
    solely so tests can substitute a fake AgentClient instead of a real
    one — mirrors the Go proxy's own Manager.pullerFactory test seam
    (internal/fleet/manager.go)."""
    async with session_factory() as session:
        agent_ids = (await session.scalars(select(Agent.id).where(Agent.enrollment_state == "enrolled"))).all()

    if not agent_ids:
        return []

    semaphore = asyncio.Semaphore(settings.poll_concurrency)
    return await asyncio.gather(
        *(poll_agent(session_factory, aid, settings, semaphore, client_factory) for aid in agent_ids)
    )


async def poller_loop(
    session_factory: async_sessionmaker[AsyncSession], settings: Settings, stop_event: asyncio.Event
) -> None:
    """Runs poll_once on settings.poll_interval_seconds until stop_event is
    set — the long-lived background task started from bossman.main's
    lifespan."""
    while not stop_event.is_set():
        try:
            results = await poll_once(session_factory, settings)
            failed = [r for r in results if r.errors]
            if failed:
                logger.warning("poll cycle: %d/%d agents had errors: %s", len(failed), len(results), failed)
        except Exception:
            logger.exception("poll cycle failed unexpectedly")

        try:
            await asyncio.wait_for(stop_event.wait(), timeout=settings.poll_interval_seconds)
        except TimeoutError:
            pass
