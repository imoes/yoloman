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
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from bossman.config import Settings, get_settings
from bossman.db.models import Agent, HostEdge, Metric
from bossman.services.agent_client import AgentClientError
from bossman.services.poller import poll_agent, poll_once


class FakeAgentClient:
    def __init__(self, metrics=None, edges=None, metrics_error=None, edges_error=None):
        self._metrics = metrics if metrics is not None else {}
        self._edges = edges if edges is not None else []
        self._metrics_error = metrics_error
        self._edges_error = edges_error
        self.metrics_calls: list = []
        self.edges_calls: list = []

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

    assert len(results) == 1
    assert results[0].agent_id == str(enrolled.id)

    await db_session.delete(enrolled)
    await db_session.delete(pending)
    await db_session.commit()
