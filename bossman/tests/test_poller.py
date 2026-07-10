"""Real, DB-backed tests for bossman.services.poller — see
tests/conftest.py's db_session fixture (skips if no DB is reachable).

Uses a FakeAgentClient (no real network) injected via poll_agent/poll_once's
client_factory parameter, mirroring the Go proxy's own
Manager.pullerFactory test seam (internal/fleet/manager.go) — this project
already established that pattern for exactly this reason: substituting a
fake network dependency while keeping every DB write real.
"""

import asyncio
import uuid

import pytest
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from bossman.config import Settings, get_settings
from bossman.db.models import Agent, HostEdge, Metric, Service, ServiceStateHistory
from bossman.services.agent_client import AgentClientError
from bossman.services.poller import poll_agent, poll_once


class FakeAgentClient:
    def __init__(
        self, metrics=None, edges=None, metrics_error=None, edges_error=None, hosts_overview=None, hosts_overview_error=None
    ):
        self._metrics = metrics if metrics is not None else {}
        self._edges = edges if edges is not None else []
        self._metrics_error = metrics_error
        self._edges_error = edges_error
        self._hosts_overview = hosts_overview if hosts_overview is not None else []
        self._hosts_overview_error = hosts_overview_error
        self.metrics_calls: list = []
        self.edges_calls: list = []
        self.hosts_overview_calls: int = 0

    async def metrics_dump(self, from_):
        self.metrics_calls.append(from_)
        if self._metrics_error:
            raise self._metrics_error
        return self._metrics

    async def connections_dump(self, since):
        self.edges_calls.append(since)
        if self._edges_error:
            raise self._edges_error
        return self._edges

    async def hosts_overview(self):
        self.hosts_overview_calls += 1
        if self._hosts_overview_error:
            raise self._hosts_overview_error
        return self._hosts_overview


@pytest.fixture
async def session_factory(db_session):  # depends on db_session purely for its reachability skip-check
    engine = create_async_engine(get_settings().database_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


def _settings(**overrides):
    kwargs = {
        "database_url": "postgresql+asyncpg://unused/unused",
        "client_cert_path": "/unused",
        "client_key_path": "/unused",
        "poll_concurrency": 5,
    }
    kwargs.update(overrides)
    return Settings(**kwargs)


async def _make_agent(db_session, **overrides) -> Agent:
    name = f"poll-{uuid.uuid4().hex[:8]}"
    fields = {"name": name, "token": "tok", "mode": "standalone", "enrollment_state": "enrolled", "address": "10.0.0.1:8010"}
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def test_poll_agent_writes_metrics_and_edges(db_session, session_factory):
    agent = await _make_agent(db_session)
    fake = FakeAgentClient(
        metrics={"cpu_pct": [{"timestamp": "2026-07-04T12:00:00Z", "value": 42.0, "labels": {"foo": "bar"}}]},
        edges=[
            {
                "comm": "curl",
                "dst_addr": "9.9.9.9",
                "dst_port": 443,
                "event_count": 3,
                "first_seen": "2026-07-04T11:00:00Z",
                "last_seen": "2026-07-04T12:00:00Z",
                "latency_ns": 5_000_000,
            }
        ],
    )

    result = await poll_agent(
        session_factory, agent.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake
    )

    assert result.metrics_written == 1
    assert result.edges_written == 1
    assert result.errors == []

    metric = await db_session.scalar(select(Metric).where(Metric.agent_id == agent.id))
    assert metric is not None
    assert metric.value == 42.0
    assert metric.labels == {"foo": "bar"}

    edge = await db_session.scalar(select(HostEdge).where(HostEdge.src_agent_id == agent.id))
    assert edge is not None
    assert str(edge.dst_addr) == "9.9.9.9"
    assert edge.event_count == 3
    assert edge.latency_ms_p50 == 5.0

    await db_session.refresh(agent)
    assert agent.last_metrics_pulled_at is not None
    assert agent.last_edges_pulled_at is not None
    assert agent.last_seen_at is not None

    await db_session.delete(metric)
    await db_session.delete(edge)
    await db_session.flush()  # children must actually delete before the FK-referenced agent
    await _purge_service_state(db_session, agent)
    await db_session.delete(agent)
    await db_session.commit()


async def test_poll_agent_records_partial_failure(db_session, session_factory):
    agent = await _make_agent(db_session)
    fake = FakeAgentClient(
        edges=[
            {
                "comm": "curl",
                "dst_addr": "9.9.9.9",
                "dst_port": 443,
                "event_count": 1,
                "first_seen": "2026-07-04T11:00:00Z",
                "last_seen": "2026-07-04T12:00:00Z",
            }
        ],
        metrics_error=AgentClientError("boom"),
    )

    result = await poll_agent(
        session_factory, agent.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake
    )

    assert result.metrics_written == 0
    assert result.edges_written == 1
    assert any("metrics: boom" in e for e in result.errors)

    await db_session.refresh(agent)
    assert agent.last_metrics_pulled_at is None  # cursor must not advance on failure
    assert agent.last_edges_pulled_at is not None
    assert agent.last_seen_at is not None  # edges succeeded, so we did reach the agent

    edge = await db_session.scalar(select(HostEdge).where(HostEdge.src_agent_id == agent.id))
    await db_session.delete(edge)
    await db_session.flush()
    await _purge_service_state(db_session, agent)
    await db_session.delete(agent)
    await db_session.commit()


async def test_poll_agent_skips_agent_without_address(db_session, session_factory):
    agent = await _make_agent(db_session, address=None)
    fake = FakeAgentClient()

    result = await poll_agent(
        session_factory, agent.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake
    )

    assert result.metrics_written == 0
    assert fake.metrics_calls == []
    assert fake.edges_calls == []

    await db_session.delete(agent)
    await db_session.commit()


async def test_poll_agent_uses_cursor_on_second_poll(db_session, session_factory):
    agent = await _make_agent(db_session)
    fake = FakeAgentClient()

    await poll_agent(session_factory, agent.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake)
    assert fake.metrics_calls == [None]  # first pull: no cursor yet

    await poll_agent(session_factory, agent.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake)
    assert fake.metrics_calls[1] is not None  # second pull: cursor from the first pull's "now"

    await _purge_service_state(db_session, agent)
    await db_session.delete(agent)
    await db_session.commit()


async def test_upsert_edges_is_idempotent_and_updates_event_count(db_session, session_factory):
    agent = await _make_agent(db_session)
    edge_body = {
        "comm": "curl",
        "dst_addr": "8.8.8.8",
        "dst_port": 443,
        "event_count": 1,
        "first_seen": "2026-07-04T11:00:00Z",
        "last_seen": "2026-07-04T12:00:00Z",
    }

    fake1 = FakeAgentClient(edges=[edge_body])
    await poll_agent(session_factory, agent.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake1)

    edge_body_v2 = {**edge_body, "event_count": 7, "last_seen": "2026-07-04T13:00:00Z"}
    fake2 = FakeAgentClient(edges=[edge_body_v2])
    await poll_agent(session_factory, agent.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake2)

    matches = (await db_session.scalars(select(HostEdge).where(HostEdge.src_agent_id == agent.id))).all()
    assert len(matches) == 1, "re-polling the same edge must update in place, not duplicate"
    assert matches[0].event_count == 7

    await db_session.delete(matches[0])
    await db_session.flush()
    await _purge_service_state(db_session, agent)
    await db_session.delete(agent)
    await db_session.commit()


async def test_poll_once_only_polls_enrolled_agents(db_session, session_factory):
    enrolled = await _make_agent(db_session)
    pending = await _make_agent(db_session, enrollment_state="pending")

    seen_addresses = []

    def factory(agent, settings):
        seen_addresses.append(agent.address)
        return FakeAgentClient()

    results = await poll_once(session_factory, _settings(), factory)

    # Assert about the two agents this test created, not a global count:
    # poll_once operates on every enrolled agent in the (shared) DB, so a
    # count assertion is fragile against residue from other tests. The
    # invariant under test is "enrolled polled, pending skipped".
    result_ids = {r.agent_id for r in results}
    assert str(enrolled.id) in result_ids
    assert str(pending.id) not in result_ids

    await _purge_service_state(db_session, enrolled, pending)
    await db_session.delete(enrolled)
    await db_session.delete(pending)
    await db_session.commit()


# ---------------------------------------------------------------------------
# GET /api/v1/hosts/overview ingestion (see docs/plan.md's monitoring-
# cockpit ergänzung Block F2) — satellite discovery + agent-reported checks.


async def _purge_service_state(db_session, *agents):
    """poll_agent evaluates any check rules present in the (shared) DB and
    persists Service + ServiceStateHistory rows for the polled agent. Those
    are NO-ACTION FKs, so a raw db_session.delete(agent) in a test's cleanup
    hits a foreign-key violation unless they're cleared first. Idempotent."""
    for agent in agents:
        await db_session.execute(delete(ServiceStateHistory).where(ServiceStateHistory.agent_id == agent.id))
        await db_session.execute(delete(Service).where(Service.agent_id == agent.id))
    await db_session.flush()


async def _cleanup_hosts_overview(db_session, *agents):
    for agent in agents:
        services = (await db_session.scalars(select(Service).where(Service.agent_id == agent.id))).all()
        for s in services:
            await db_session.delete(s)
        history = (await db_session.scalars(select(ServiceStateHistory).where(ServiceStateHistory.agent_id == agent.id))).all()
        for h in history:
            await db_session.delete(h)
        metrics = (await db_session.scalars(select(Metric).where(Metric.agent_id == agent.id))).all()
        for m in metrics:
            await db_session.delete(m)
        await db_session.flush()
    for agent in agents:
        await db_session.delete(agent)
        await db_session.flush()  # respect parent_agent_id FK ordering (satellite before proxy)
    await db_session.commit()


async def test_poll_agent_discovers_satellite_from_hosts_overview(db_session, session_factory):
    proxy = await _make_agent(db_session, mode="proxy")
    fake = FakeAgentClient(
        hosts_overview=[
            {"host": proxy.name, "mode": "proxy", "metrics": [], "checks": []},
            {
                "host": "duppy-satellite-1",
                "parent": proxy.name,
                "mode": "satellite",
                "last_sample_at": "2026-07-06T12:00:00Z",
                "metrics": [{"metric": "cpu_load1", "value": 0.42, "labels": {}}],
                "checks": [{"name": "Memory", "status": "OK", "message": "18% used"}],
            },
        ]
    )

    result = await poll_agent(session_factory, proxy.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake)
    assert result.satellites_discovered == 1
    assert result.errors == []

    satellite = await db_session.scalar(select(Agent).where(Agent.name == "duppy-satellite-1"))
    assert satellite is not None, "the satellite must become its own first-class Agent row"
    assert satellite.parent_agent_id == proxy.id
    assert satellite.mode == "satellite"
    assert satellite.enrollment_state == "enrolled"
    assert satellite.last_seen_at is not None

    metric = await db_session.scalar(select(Metric).where(Metric.agent_id == satellite.id, Metric.metric == "cpu_load1"))
    assert metric is not None
    assert metric.value == 0.42

    service = await db_session.scalar(select(Service).where(Service.agent_id == satellite.id, Service.name == "Memory"))
    assert service is not None
    assert service.state == "OK"
    assert service.rule_id is None, "an agent-reported check is not derived from a Bossman check_rule"

    await _cleanup_hosts_overview(db_session, satellite, proxy)


async def test_poll_agent_ingests_self_checks_from_hosts_overview(db_session, session_factory):
    agent = await _make_agent(db_session)
    fake = FakeAgentClient(
        hosts_overview=[
            {
                "host": agent.name,
                "mode": "standalone",
                "metrics": [],
                "checks": [{"name": "Disk /", "status": "CRITICAL", "message": "95% used"}],
            }
        ]
    )

    result = await poll_agent(session_factory, agent.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake)
    assert result.satellites_discovered == 0

    service = await db_session.scalar(select(Service).where(Service.agent_id == agent.id, Service.name == "Disk /"))
    assert service is not None
    assert service.state == "CRIT", "checks.Status CRITICAL must map onto Service.state's own CRIT vocabulary"

    await _cleanup_hosts_overview(db_session, agent)


async def test_poll_agent_stores_inventory_facts(db_session, session_factory):
    """The hosts/overview inventory document lands in agents.facts (Block
    H2), for the self host and satellites alike — and a re-poll whose only
    difference is the agent's re-stamped collected_at must NOT bump
    facts_updated_at (the inventory is near-static)."""
    proxy = await _make_agent(db_session, mode="proxy")
    inv = {
        "collected_at": "2026-07-07T10:00:00Z",
        "system": {"manufacturer": "QEMU", "serial_number": "SN-1"},
        "cpu": {"model": "Intel Xeon Gold 6338", "threads": 8},
    }
    sat_inv = {"collected_at": "2026-07-07T10:00:00Z", "system": {"manufacturer": "VMware"}}
    fake = FakeAgentClient(
        hosts_overview=[
            {"host": proxy.name, "mode": "proxy", "metrics": [], "checks": [], "inventory": inv},
            {"host": "duppy-inv-sat", "parent": proxy.name, "mode": "satellite", "metrics": [], "checks": [], "inventory": sat_inv},
        ]
    )

    result = await poll_agent(session_factory, proxy.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake)
    assert result.errors == []

    await db_session.refresh(proxy)
    assert proxy.facts["system"]["serial_number"] == "SN-1"
    assert proxy.facts["cpu"]["model"] == "Intel Xeon Gold 6338"
    first_updated = proxy.facts_updated_at
    assert first_updated is not None

    satellite = await db_session.scalar(select(Agent).where(Agent.name == "duppy-inv-sat"))
    assert satellite.facts["system"]["manufacturer"] == "VMware"

    # Re-poll: same document, only collected_at re-stamped → no churn.
    fake._hosts_overview[0]["inventory"] = dict(inv, collected_at="2026-07-07T11:00:00Z")
    await poll_agent(session_factory, proxy.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake)
    await db_session.refresh(proxy)
    assert proxy.facts_updated_at == first_updated, "collected_at alone must not count as a facts change"

    await _cleanup_hosts_overview(db_session, satellite, proxy)


async def test_poll_agent_self_entry_identified_by_missing_parent_not_by_name(db_session, session_factory):
    """Real bug, caught against the actual running stack: the Go agent
    reports its own OS hostname as `host` (os.Hostname()), which need not
    match the arbitrary name Bossman enrolled it under. Matching the self
    entry by `host == agent.name` misfiled the proxy's own entry as a
    bogus satellite of itself whenever the two names differed — the fix
    is to identify the self entry by an absent `parent` field instead."""
    proxy = await _make_agent(db_session, mode="proxy", name="selecta-friendly-name")
    fake = FakeAgentClient(
        hosts_overview=[
            # No "parent" key at all -> this is the self entry, even
            # though its reported hostname doesn't match agent.name.
            {"host": "host2.example.internal", "mode": "proxy", "metrics": [], "checks": []},
        ]
    )

    result = await poll_agent(session_factory, proxy.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake)

    assert result.satellites_discovered == 0
    bogus = await db_session.scalar(select(Agent).where(Agent.name == "host2.example.internal"))
    assert bogus is None, "the proxy's own self entry must never become a satellite Agent row"

    await _purge_service_state(db_session, proxy)
    await db_session.delete(proxy)
    await db_session.commit()


async def test_poll_agent_reuses_existing_satellite_across_polls(db_session, session_factory):
    proxy = await _make_agent(db_session, mode="proxy")
    fake = FakeAgentClient(
        hosts_overview=[
            {"host": proxy.name, "mode": "proxy", "metrics": [], "checks": []},
            {"host": "duppy-satellite-2", "parent": proxy.name, "mode": "satellite", "metrics": [], "checks": []},
        ]
    )

    await poll_agent(session_factory, proxy.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake)
    await poll_agent(session_factory, proxy.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake)

    matches = (await db_session.scalars(select(Agent).where(Agent.name == "duppy-satellite-2"))).all()
    assert len(matches) == 1, "re-polling the same satellite must not create a duplicate Agent row"

    await _cleanup_hosts_overview(db_session, matches[0], proxy)


async def test_poll_agent_keeps_same_timestamp_multi_label_metrics(db_session, session_factory):
    """Metric's primary key is (time, agent_id, metric) — it does not
    include labels. The real Go agent's sampler timestamps every point in
    one tick identically (see internal/collect.Sample), so two mounts'
    disk_used_pct values naturally collide on that key. Without
    poller._disambiguate_colliding_timestamps, ON CONFLICT DO NOTHING
    would silently keep only one of them."""
    agent = await _make_agent(db_session)
    same_ts = "2026-07-06T12:00:00Z"
    fake = FakeAgentClient(
        metrics={
            "disk_used_pct": [
                {"timestamp": same_ts, "value": 10.0, "labels": {"mount": "/"}},
                {"timestamp": same_ts, "value": 91.2, "labels": {"mount": "/data"}},
            ]
        }
    )

    result = await poll_agent(session_factory, agent.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake)
    assert result.metrics_written == 2

    rows = (await db_session.scalars(select(Metric).where(Metric.agent_id == agent.id, Metric.metric == "disk_used_pct"))).all()
    assert len(rows) == 2, "both mounts' data points must survive, not just one"
    assert {r.labels["mount"] for r in rows} == {"/", "/data"}

    for r in rows:
        await db_session.delete(r)
    await db_session.flush()
    await _purge_service_state(db_session, agent)
    await db_session.delete(agent)
    await db_session.commit()


async def test_poll_agent_records_hosts_overview_failure(db_session, session_factory):
    agent = await _make_agent(db_session)
    fake = FakeAgentClient(hosts_overview_error=AgentClientError("boom"))

    result = await poll_agent(session_factory, agent.id, _settings(), asyncio.Semaphore(1), lambda a, s: fake)

    assert any("hosts_overview" in e for e in result.errors)

    await _purge_service_state(db_session, agent)
    await db_session.delete(agent)
    await db_session.commit()
