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

from bossman.db.models import Agent, Downtime, HostParent, MetricRaw, MetricSeries, Service, ServiceStateHistory
from bossman.services.monitoring import (
    DEFAULT_MAX_ATTEMPTS,
    HOST_ALIVE_SERVICE,
    hard_down_agent_ids,
    is_in_downtime,
    newest_sample_at,
    parent_ids,
    unreachable_via,
    update_host_alive,
)

# Wide enough that a fresh sample written by the test is never accidentally stale.
STALE_AFTER = timedelta(minutes=4)


async def _sample(db_session, agent, when=None, value=1.0):
    """Give the host a metric sample — its data freshness IS its up/down signal now."""
    series = MetricSeries(agent_id=agent.id, metric="cpu_pct", labels={})
    db_session.add(series)
    await db_session.flush()
    db_session.add(MetricRaw(series_id=series.series_id, time=when or datetime.now(timezone.utc), value=value))
    await db_session.flush()
    return series


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
    ids = list((await db_session.scalars(select(MetricSeries.series_id).where(MetricSeries.agent_id == agent.id))).all())
    if ids:
        await db_session.execute(delete(MetricRaw).where(MetricRaw.series_id.in_(ids)))
        await db_session.execute(delete(MetricSeries).where(MetricSeries.series_id.in_(ids)))
    await db_session.execute(delete(ServiceStateHistory).where(ServiceStateHistory.agent_id == agent.id))
    await db_session.execute(delete(Service).where(Service.agent_id == agent.id))
    await db_session.execute(delete(Downtime).where(Downtime.agent_id == agent.id))
    await db_session.execute(delete(HostParent).where(HostParent.child_agent_id == agent.id))
    await db_session.execute(delete(HostParent).where(HostParent.parent_agent_id == agent.id))
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def _host_service(db_session, agent) -> Service:
    return await db_session.scalar(
        select(Service).where(Service.agent_id == agent.id, Service.name == HOST_ALIVE_SERVICE)
    )


async def test_a_reached_host_with_fresh_data_is_ok(db_session):
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    await _sample(db_session, agent, when=now - timedelta(seconds=30))

    svc = await update_host_alive(db_session, agent, reached=True, now=now, stale_after=STALE_AFTER)
    await db_session.commit()

    assert svc.name == HOST_ALIVE_SERVICE
    assert svc.state == "OK"
    assert "data" in svc.output, f"the age of the data belongs in the summary: {svc.output!r}"
    await _cleanup(db_session, agent)


async def test_an_unreachable_host_is_critical(db_session):
    """The product rule: down means CRIT, not UNKNOWN and not merely "stale"."""
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)

    for i in range(DEFAULT_MAX_ATTEMPTS):
        svc = await update_host_alive(db_session, agent, reached=False, now=now + timedelta(seconds=i), stale_after=STALE_AFTER)
    await db_session.commit()

    assert svc.state == "CRIT"
    assert svc.state_type == "hard", "after max_attempts the problem must be confirmed"
    await _cleanup(db_session, agent)


async def test_one_dropped_poll_does_not_page(db_session):
    """Debounced: a single failure is soft, so a blip in the network is not an outage."""
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)

    svc = await update_host_alive(db_session, agent, reached=False, now=now, stale_after=STALE_AFTER)
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
        db_session, agent, reached=False, now=now, stale_after=STALE_AFTER, detail="metrics: connect timeout"
    )
    await db_session.commit()

    assert "10.0.0.9:9000" in svc.output
    assert "connect timeout" in svc.output
    await _cleanup(db_session, agent)


async def test_recovery_returns_to_ok(db_session):
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    for i in range(DEFAULT_MAX_ATTEMPTS):
        await update_host_alive(db_session, agent, reached=False, now=now + timedelta(seconds=i), stale_after=STALE_AFTER)
    await db_session.commit()

    await _sample(db_session, agent, when=now + timedelta(seconds=55))
    svc = await update_host_alive(db_session, agent, reached=True, now=now + timedelta(seconds=60), stale_after=STALE_AFTER)
    await db_session.commit()

    assert svc.state == "OK"
    assert svc.state_type == "hard"
    await _cleanup(db_session, agent)


async def test_hard_down_is_reported_only_once_confirmed(db_session):
    """L3's input: a soft failure must not yet silence the host's other services."""
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)

    await update_host_alive(db_session, agent, reached=False, now=now, stale_after=STALE_AFTER)
    await db_session.commit()
    assert await hard_down_agent_ids(db_session, [agent.id]) == set(), "soft is not yet down"

    for i in range(1, DEFAULT_MAX_ATTEMPTS):
        await update_host_alive(db_session, agent, reached=False, now=now + timedelta(seconds=i), stale_after=STALE_AFTER)
    await db_session.commit()
    assert await hard_down_agent_ids(db_session, [agent.id]) == {agent.id}

    await _cleanup(db_session, agent)


async def test_hard_down_ignores_hosts_that_are_up(db_session):
    up = await _make_agent(db_session)
    down = await _make_agent(db_session)
    now = datetime.now(timezone.utc)

    await _sample(db_session, up, when=now - timedelta(seconds=10))
    await update_host_alive(db_session, up, reached=True, now=now, stale_after=STALE_AFTER)
    for i in range(DEFAULT_MAX_ATTEMPTS):
        await update_host_alive(db_session, down, reached=False, now=now + timedelta(seconds=i), stale_after=STALE_AFTER)
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
        await update_host_alive(db_session, agent, reached=False, now=now + timedelta(seconds=i), stale_after=STALE_AFTER)
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


# ---------------------------------------------------------------------------
# Agent status IS the ping: a stale agent means the host is down (Checkmk parity)


async def test_a_reachable_but_stale_agent_is_down(db_session):
    """The port answers, the data does not. Checkmk equates agent contact with the host
    check, so a stale agent is a DOWN host — an agent whose sampler has died is not a
    healthy host just because its HTTP listener still accepts connections.
    """
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    await _sample(db_session, agent, when=now - timedelta(hours=3))

    for i in range(DEFAULT_MAX_ATTEMPTS):
        svc = await update_host_alive(
            db_session, agent, reached=True, now=now + timedelta(seconds=i), stale_after=STALE_AFTER
        )
    await db_session.commit()

    assert svc.state == "CRIT"
    assert svc.state_type == "hard"
    assert "stale" in svc.output
    assert "did answer" in svc.output, "must not read as a network fault — the API responded"
    await _cleanup(db_session, agent)


async def test_a_host_that_never_delivered_is_down(db_session):
    """Distinct wording from "stale": there is no last sample to be old."""
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)

    svc = await update_host_alive(db_session, agent, reached=True, now=now, stale_after=STALE_AFTER)
    await db_session.commit()

    assert svc.state == "CRIT"
    assert "never delivered" in svc.output
    await _cleanup(db_session, agent)


async def test_a_satellite_is_judged_by_freshness_alone(db_session):
    """reached=None: Bossman never contacts a satellite directly.

    Its data arrives relayed through a proxy, so freshness is the only signal there is.
    Before this, satellites had no host verdict at all and a relay that quietly stopped
    delivering looked exactly like a healthy host — worse, the proxy's own successful
    poll kept refreshing the satellite's last_seen_at.
    """
    fresh = await _make_agent(db_session)
    stale = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    await _sample(db_session, fresh, when=now - timedelta(seconds=20))
    await _sample(db_session, stale, when=now - timedelta(hours=2))

    ok = await update_host_alive(db_session, fresh, reached=None, now=now, stale_after=STALE_AFTER)
    bad = await update_host_alive(db_session, stale, reached=None, now=now, stale_after=STALE_AFTER)
    await db_session.commit()

    assert ok.state == "OK" and "relayed" in ok.output
    assert bad.state == "CRIT" and "stale" in bad.output
    assert "did answer" not in bad.output, "nothing answered — we never contacted it"

    await _cleanup(db_session, fresh)
    await _cleanup(db_session, stale)


async def test_the_agent_version_is_shown(db_session):
    """Checkmk shows the agent version with its agent service; so do we, in both verdicts."""
    agent = await _make_agent(db_session)
    agent.agent_version = "0.57.36"
    now = datetime.now(timezone.utc)
    await _sample(db_session, agent, when=now - timedelta(seconds=15))

    ok = await update_host_alive(db_session, agent, reached=True, now=now, stale_after=STALE_AFTER)
    await db_session.commit()
    assert "v0.57.36" in ok.output

    await _cleanup(db_session, agent)


async def test_no_version_yet_does_not_print_an_empty_v(db_session):
    """"" means not asked yet — it must not surface as a bare "v"."""
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    await _sample(db_session, agent, when=now - timedelta(seconds=15))

    ok = await update_host_alive(db_session, agent, reached=True, now=now, stale_after=STALE_AFTER)
    await db_session.commit()
    assert " v" not in ok.output and ok.state == "OK"

    await _cleanup(db_session, agent)


async def test_newest_sample_at_is_none_without_data(db_session):
    agent = await _make_agent(db_session)
    assert await newest_sample_at(db_session, agent.id) is None
    await _cleanup(db_session, agent)


def test_version_suffix_only_prefixes_a_real_version():
    """The infra poller reports "poller", which " v" turned into "vpoller"."""
    from bossman.services.monitoring import _version_suffix

    assert _version_suffix("0.57.36") == " v0.57.36"
    assert _version_suffix("poller") == " (poller)"
    assert _version_suffix("") == ""
    assert _version_suffix("  ") == ""


# ---------------------------------------------------------------------------
# L6 — UNREACHABLE is not DOWN: "the switch is dead, not the 40 hosts behind it"


async def _down(db_session, agent, now):
    """Drive a host to hard-down."""
    for i in range(DEFAULT_MAX_ATTEMPTS):
        await update_host_alive(
            db_session, agent, reached=False, now=now + timedelta(seconds=i), stale_after=STALE_AFTER
        )
    await db_session.commit()


async def test_a_host_behind_a_dead_parent_is_unreachable_not_down(db_session):
    """The whole point: its own state is unknown, not bad, and it must not page."""
    switch = await _make_agent(db_session)
    host = await _make_agent(db_session)
    db_session.add(HostParent(child_agent_id=host.id, parent_agent_id=switch.id))
    await db_session.commit()
    now = datetime.now(timezone.utc)

    await _down(db_session, switch, now)
    svc = await update_host_alive(db_session, host, reached=False, now=now, stale_after=STALE_AFTER)
    await db_session.commit()

    assert svc.state == "UNKNOWN", "not CRIT — we cannot tell whether this host is fine"
    assert "unreachable" in svc.output
    assert switch.name in svc.output, "name the parent that is actually down"
    assert getattr(svc, "_unreachable", False) is True, "and do not page for it"

    await _cleanup(db_session, host)
    await _cleanup(db_session, switch)


async def test_one_reachable_parent_makes_it_the_hosts_own_fault(db_session):
    """Checkmk's rule, and the reason parents are a list."""
    dead = await _make_agent(db_session)
    alive = await _make_agent(db_session)
    host = await _make_agent(db_session)
    db_session.add(HostParent(child_agent_id=host.id, parent_agent_id=dead.id))
    db_session.add(HostParent(child_agent_id=host.id, parent_agent_id=alive.id))
    await db_session.commit()
    now = datetime.now(timezone.utc)

    await _down(db_session, dead, now)
    await _sample(db_session, alive, when=now - timedelta(seconds=10))
    await update_host_alive(db_session, alive, reached=True, now=now, stale_after=STALE_AFTER)
    await db_session.commit()

    svc = await update_host_alive(db_session, host, reached=False, now=now, stale_after=STALE_AFTER)
    await db_session.commit()

    assert svc.state == "CRIT", "a path to it exists, so its silence is its own problem"
    assert "no answer" in svc.output

    await _cleanup(db_session, host)
    await _cleanup(db_session, dead)
    await _cleanup(db_session, alive)


async def test_a_soft_down_parent_does_not_yet_excuse_the_child(db_session):
    """One dropped poll on the switch must not reclassify everything behind it."""
    switch = await _make_agent(db_session)
    host = await _make_agent(db_session)
    db_session.add(HostParent(child_agent_id=host.id, parent_agent_id=switch.id))
    await db_session.commit()
    now = datetime.now(timezone.utc)

    await update_host_alive(db_session, switch, reached=False, now=now, stale_after=STALE_AFTER)
    await db_session.commit()
    assert await unreachable_via(db_session, host) == [], "soft is not confirmed down"

    svc = await update_host_alive(db_session, host, reached=False, now=now, stale_after=STALE_AFTER)
    await db_session.commit()
    assert svc.state == "CRIT"

    await _cleanup(db_session, host)
    await _cleanup(db_session, switch)


async def test_a_host_with_no_parent_is_simply_down(db_session):
    """No topology configured must not change today's behaviour."""
    host = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    assert await parent_ids(db_session, host) == []

    svc = await update_host_alive(db_session, host, reached=False, now=now, stale_after=STALE_AFTER)
    await db_session.commit()
    assert svc.state == "CRIT"
    await _cleanup(db_session, host)


async def test_the_proxy_relation_counts_as_a_parent_without_configuration(db_session):
    """If Bossman cannot reach a proxy it cannot reach the satellites behind it — true
    without anyone configuring it, and already the case for minikube/nginx behind
    docker-test on this fleet."""
    proxy = await _make_agent(db_session)
    satellite = await _make_agent(db_session)
    satellite.parent_agent_id = proxy.id
    await db_session.commit()
    now = datetime.now(timezone.utc)

    assert await parent_ids(db_session, satellite) == [proxy.id]
    await _down(db_session, proxy, now)

    svc = await update_host_alive(db_session, satellite, reached=False, now=now, stale_after=STALE_AFTER)
    await db_session.commit()
    assert svc.state == "UNKNOWN" and proxy.name in svc.output

    await _cleanup(db_session, satellite)
    await _cleanup(db_session, proxy)


async def test_an_explicit_parent_is_not_duplicated_by_the_proxy(db_session):
    """Configuring the proxy explicitly as well must not count it twice — otherwise the
    all-parents-down test could never be satisfied."""
    proxy = await _make_agent(db_session)
    satellite = await _make_agent(db_session)
    satellite.parent_agent_id = proxy.id
    db_session.add(HostParent(child_agent_id=satellite.id, parent_agent_id=proxy.id))
    await db_session.commit()

    assert await parent_ids(db_session, satellite) == [proxy.id]
    await _cleanup(db_session, satellite)
    await _cleanup(db_session, proxy)
