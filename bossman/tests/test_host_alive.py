"""L2/L3: a host that does not answer is CRIT, and it reports ONE problem, not N.

The decision behind this: being down is a problem in its own right, unless a downtime
says it is expected. It is carried as a reserved Service ("Host alive") rather than as
new columns on `agents`, which is why it inherits soft/hard debouncing, history,
acknowledgement, downtime coverage, the Problems view, notification rules and escalation
without any of them being rebuilt.
"""

import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select

from bossman.db.models import Agent, Downtime, Service, ServiceStateHistory
from bossman.services.monitoring import (
    DEFAULT_MAX_ATTEMPTS,
    HOST_ALIVE_SERVICE,
    hard_down_agent_ids,
    is_in_downtime,
    update_host_alive,
)


async def _make_agent(db_session, name=None) -> Agent:
    agent = Agent(
        name=name or f"halive-{uuid.uuid4().hex[:8]}",
        address="10.0.0.9:9000",
        token=uuid.uuid4().hex,
        enrollment_state="enrolled",
    )
    db_session.add(agent)
    await db_session.commit()
    return agent


async def _cleanup(db_session, agent):
    await db_session.execute(delete(ServiceStateHistory).where(ServiceStateHistory.agent_id == agent.id))
    await db_session.execute(delete(Service).where(Service.agent_id == agent.id))
    await db_session.execute(delete(Downtime).where(Downtime.agent_id == agent.id))
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def _host_service(db_session, agent) -> Service:
    return await db_session.scalar(
        select(Service).where(Service.agent_id == agent.id, Service.name == HOST_ALIVE_SERVICE)
    )


async def test_a_reached_host_is_ok(db_session):
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)

    svc = await update_host_alive(db_session, agent, reached=True, now=now)
    await db_session.commit()

    assert svc.name == HOST_ALIVE_SERVICE
    assert svc.state == "OK"
    await _cleanup(db_session, agent)


async def test_an_unreachable_host_is_critical(db_session):
    """The product rule: down means CRIT, not UNKNOWN and not merely "stale"."""
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)

    for i in range(DEFAULT_MAX_ATTEMPTS):
        svc = await update_host_alive(db_session, agent, reached=False, now=now + timedelta(seconds=i))
    await db_session.commit()

    assert svc.state == "CRIT"
    assert svc.state_type == "hard", "after max_attempts the problem must be confirmed"
    await _cleanup(db_session, agent)


async def test_one_dropped_poll_does_not_page(db_session):
    """Debounced: a single failure is soft, so a blip in the network is not an outage."""
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)

    svc = await update_host_alive(db_session, agent, reached=False, now=now)
    await db_session.commit()

    assert svc.state == "CRIT"
    assert svc.state_type == "soft"
    assert getattr(svc, "_notify_event", None) is None, "a soft state must not notify"
    await _cleanup(db_session, agent)


async def test_the_output_names_the_reason(db_session):
    """"no answer" alone sends the operator hunting for what the poller already knows."""
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)

    svc = await update_host_alive(
        db_session, agent, reached=False, now=now, detail="metrics: connect timeout"
    )
    await db_session.commit()

    assert "10.0.0.9:9000" in svc.output
    assert "connect timeout" in svc.output
    await _cleanup(db_session, agent)


async def test_recovery_returns_to_ok(db_session):
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    for i in range(DEFAULT_MAX_ATTEMPTS):
        await update_host_alive(db_session, agent, reached=False, now=now + timedelta(seconds=i))
    await db_session.commit()

    svc = await update_host_alive(db_session, agent, reached=True, now=now + timedelta(seconds=60))
    await db_session.commit()

    assert svc.state == "OK"
    assert svc.state_type == "hard"
    await _cleanup(db_session, agent)


async def test_hard_down_is_reported_only_once_confirmed(db_session):
    """L3's input: a soft failure must not yet silence the host's other services."""
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)

    await update_host_alive(db_session, agent, reached=False, now=now)
    await db_session.commit()
    assert await hard_down_agent_ids(db_session, [agent.id]) == set(), "soft is not yet down"

    for i in range(1, DEFAULT_MAX_ATTEMPTS):
        await update_host_alive(db_session, agent, reached=False, now=now + timedelta(seconds=i))
    await db_session.commit()
    assert await hard_down_agent_ids(db_session, [agent.id]) == {agent.id}

    await _cleanup(db_session, agent)


async def test_hard_down_ignores_hosts_that_are_up(db_session):
    up = await _make_agent(db_session)
    down = await _make_agent(db_session)
    now = datetime.now(timezone.utc)

    await update_host_alive(db_session, up, reached=True, now=now)
    for i in range(DEFAULT_MAX_ATTEMPTS):
        await update_host_alive(db_session, down, reached=False, now=now + timedelta(seconds=i))
    await db_session.commit()

    assert await hard_down_agent_ids(db_session, [up.id, down.id]) == {down.id}
    await _cleanup(db_session, up)
    await _cleanup(db_session, down)


async def test_empty_input_asks_nothing(db_session):
    """Guarded so a poll cycle that touched no service does not emit an IN () query."""
    assert await hard_down_agent_ids(db_session, []) == set()


async def test_a_host_downtime_covers_the_host_service(db_session):
    """"Critical unless a downtime is set" — no special case needed for the host.

    A host-wide downtime is a Downtime row with service_name NULL, and the existing
    is_in_downtime already treats that as covering every service on the host. So the
    state stays honestly CRIT while the page is suppressed and the Problems view drops
    it, exactly as for any other service.
    """
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    db_session.add(
        Downtime(
            agent_id=agent.id,
            service_name=None,  # the whole host
            starts_at=now - timedelta(minutes=5),
            ends_at=now + timedelta(hours=1),
            comment="planned reboot",
        )
    )
    for i in range(DEFAULT_MAX_ATTEMPTS):
        await update_host_alive(db_session, agent, reached=False, now=now + timedelta(seconds=i))
    await db_session.commit()

    svc = await _host_service(db_session, agent)
    assert svc.state == "CRIT", "the downtime hides the alert, it does not falsify the state"
    assert await is_in_downtime(db_session, agent.id, HOST_ALIVE_SERVICE, now) is True

    await _cleanup(db_session, agent)


async def test_an_expired_downtime_no_longer_covers_the_host(db_session):
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    db_session.add(
        Downtime(
            agent_id=agent.id,
            service_name=None,
            starts_at=now - timedelta(hours=2),
            ends_at=now - timedelta(minutes=1),
            comment="window is over",
        )
    )
    await db_session.commit()

    assert await is_in_downtime(db_session, agent.id, HOST_ALIVE_SERVICE, now) is False
    await _cleanup(db_session, agent)
