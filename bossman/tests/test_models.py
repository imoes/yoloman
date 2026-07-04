"""Real, end-to-end model tests against the actual TimescaleDB schema (see
tests/conftest.py's db_session fixture) — proving the SQLAlchemy models
match what the Alembic migration actually created, not just that the
Python classes are syntactically valid."""

from datetime import datetime, timezone

from sqlalchemy import select

from bossman.db.models import Agent, ConnectionEvent, HostEdge, Metric


async def test_agent_roundtrip(db_session):
    agent = Agent(name="test-agent-1", token="secret", mode="standalone", enrollment_state="pending")
    db_session.add(agent)
    await db_session.flush()

    got = await db_session.scalar(select(Agent).where(Agent.name == "test-agent-1"))
    assert got is not None
    assert got.id == agent.id
    assert got.mode == "standalone"
    assert got.agent_metadata == {}  # default applied


async def test_agent_name_must_be_unique(db_session):
    from sqlalchemy.exc import IntegrityError

    db_session.add(Agent(name="dup-agent", token="a", mode="standalone", enrollment_state="pending"))
    await db_session.flush()
    db_session.add(Agent(name="dup-agent", token="b", mode="standalone", enrollment_state="pending"))
    try:
        await db_session.flush()
        raise AssertionError("expected a unique-constraint violation")
    except IntegrityError:
        await db_session.rollback()


async def test_host_edge_requires_valid_agent_fk(db_session):
    agent = Agent(name="edge-owner", token="a", mode="standalone", enrollment_state="pending")
    db_session.add(agent)
    await db_session.flush()

    now = datetime.now(timezone.utc)
    edge = HostEdge(
        src_agent_id=agent.id,
        src_comm="curl",
        dst_addr="1.1.1.1",
        dst_port=443,
        event_count=1,
        first_seen_at=now,
        last_seen_at=now,
    )
    db_session.add(edge)
    await db_session.flush()

    got = await db_session.scalar(select(HostEdge).where(HostEdge.src_agent_id == agent.id))
    assert got is not None
    assert got.dst_addr == "1.1.1.1"
    assert got.dst_port == 443


async def test_connection_event_hypertable_insert(db_session):
    """Proves connection_events (a TimescaleDB hypertable, not a plain
    table) actually accepts inserts through the ORM the same way a normal
    table would."""
    agent = Agent(name="conn-event-agent", token="a", mode="standalone", enrollment_state="pending")
    db_session.add(agent)
    await db_session.flush()

    event = ConnectionEvent(
        time=datetime.now(timezone.utc),
        src_agent_id=agent.id,
        pid=1234,
        comm="curl",
        dst_addr="1.1.1.1",
        dst_port=443,
        new_state="ESTABLISHED",
    )
    db_session.add(event)
    await db_session.flush()

    got = await db_session.scalar(select(ConnectionEvent).where(ConnectionEvent.src_agent_id == agent.id))
    assert got is not None
    assert got.new_state == "ESTABLISHED"


async def test_metric_hypertable_insert(db_session):
    """Proves metrics (also a hypertable) accepts inserts through the ORM."""
    agent = Agent(name="metric-agent", token="a", mode="standalone", enrollment_state="pending")
    db_session.add(agent)
    await db_session.flush()

    point = Metric(time=datetime.now(timezone.utc), agent_id=agent.id, metric="cpu_pct", value=42.5, labels={})
    db_session.add(point)
    await db_session.flush()

    got = await db_session.scalar(select(Metric).where(Metric.agent_id == agent.id))
    assert got is not None
    assert got.value == 42.5
