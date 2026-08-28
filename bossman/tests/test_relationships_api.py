"""End-to-end tests for /api/v1/relationships — real HTTP, real Postgres
(see tests/conftest.py's db_session fixture), real API-token auth.
"""

import uuid

import pytest

from tests.naming import owned_name
from datetime import datetime, timezone

from fastapi.testclient import TestClient

from bossman.db.models import Agent, HostEdge
from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _make_agent(db_session) -> Agent:
    agent = Agent(name=owned_name("rel-agent"), token="tok", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _make_edge(db_session, agent, dst_addr="9.9.9.9", dst_port=443, comm="curl",
                     event_count=5, latency=1.5) -> HostEdge:
    now = datetime.now(timezone.utc)
    edge = HostEdge(
        src_agent_id=agent.id,
        src_comm=comm,
        dst_addr=dst_addr,
        dst_port=dst_port,
        event_count=event_count,
        first_seen_at=now,
        last_seen_at=now,
        latency_ms_p50=latency,
    )
    db_session.add(edge)
    await db_session.flush()
    await db_session.commit()
    return edge


async def _make_api_token(db_session):
    row, raw = new_api_token("rel-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def test_relationships_requires_auth():
    app = create_app()
    with TestClient(app) as client:
        resp = client.get("/api/v1/relationships")
    assert resp.status_code == 401


async def test_list_relationships_filtered_by_agent(db_session):
    agent_a = await _make_agent(db_session)
    agent_b = await _make_agent(db_session)
    edge_a = await _make_edge(db_session, agent_a, dst_addr="1.1.1.1")
    edge_b = await _make_edge(db_session, agent_b, dst_addr="2.2.2.2")
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/relationships?agent_id={agent_a.id}", headers=_headers(raw))

    assert resp.status_code == 200
    body = resp.json()
    assert len(body["groups"]) == 1
    assert body["groups"][0]["dst_addr"] == "1.1.1.1"
    assert body["groups"][0]["event_count"] == 5
    # One edge in the group, so its single port and its own p50 are the answer.
    assert body["groups"][0]["dst_port"] == 443
    assert body["groups"][0]["ports"] == 1
    assert body["groups"][0]["latency_ms_p50_busiest"] == 1.5
    assert body["total_edges"] == 1 and body["total_groups"] == 1
    assert body["truncated"] is False
    # No raw edges unless asked for: the whole point is not shipping them by default.
    assert body["edges"] is None

    await db_session.delete(edge_a)
    await db_session.delete(edge_b)
    await db_session.flush()
    await db_session.delete(agent_a)
    await db_session.delete(agent_b)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_unfiltered_is_capped_and_says_so(db_session):
    """The fleet-wide call is a TOP-N now, and this test is the reason it has to admit it.

    It used to assert that an unfiltered call returns every edge, and it passed because there was no cap.
    Against a real fleet that is 28 203 rows from one host alone, and a freshly written 5-event test edge is
    nowhere near the busiest 200 — so the honest contract is: unfiltered gives the busiest groups plus the
    totals, and a caller that wants one host's edges asks for that host."""
    agent = await _make_agent(db_session)
    edge = await _make_edge(db_session, agent)
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    with TestClient(app) as client:
        wide = client.get("/api/v1/relationships", headers=_headers(raw))
        mine = client.get(f"/api/v1/relationships?agent_id={agent.id}", headers=_headers(raw))

    assert wide.status_code == 200
    body = wide.json()
    # The totals are fleet-wide and complete even when the page is not.
    assert body["total_edges"] >= 1 and body["total_groups"] >= 1
    if body["total_groups"] > len(body["groups"]):
        assert body["truncated"] is True, "a capped answer that does not say so looks complete"
    # Filtered, the edge is always there — that is the query a host page makes.
    assert any(g["src_agent_id"] == str(agent.id) for g in mine.json()["groups"])

    await db_session.delete(edge)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_ephemeral_ports_collapse_into_one_group(db_session):
    """THE CASE THIS ENDPOINT EXISTS FOR. Measured on a real host: kubelet had 14 119 rows to 127.0.0.1,
    one per ephemeral port, and the reply was 5.46 MB — a "relationship list" nobody can read. The fact is
    "kubelet talks to 127.0.0.1", once, standing for 14 119 connections."""
    agent = await _make_agent(db_session)
    made = [await _make_edge(db_session, agent, dst_addr="127.0.0.1", dst_port=40000 + i,
                             comm="kubelet", event_count=10 + i, latency=0.05 + i / 1000)
            for i in range(5)]
    made.append(await _make_edge(db_session, agent, dst_addr="10.0.0.9", dst_port=443, comm="curl"))
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/relationships?agent_id={agent.id}", headers=_headers(raw))
    body = resp.json()

    assert body["total_edges"] == 6, "the totals must still count every raw edge"
    assert body["total_groups"] == 2
    by_comm = {g["src_comm"]: g for g in body["groups"]}
    kubelet = by_comm["kubelet"]
    assert kubelet["ports"] == 5 and kubelet["edges"] == 5
    # No single port is named for a multi-port group: picking one of five (or of 14 119) would present an
    # arbitrary example as the answer.
    assert kubelet["dst_port"] is None
    assert kubelet["event_count"] == sum(10 + i for i in range(5))
    # The BUSIEST edge's p50 — not max(), which on the real host reported 57 804 453 ms (16 hours) because
    # one dead connection's timeout is in there.
    assert kubelet["latency_ms_p50_busiest"] == pytest.approx(0.054)
    # Busiest first, so a cap keeps what matters.
    assert body["groups"][0]["src_comm"] == "kubelet"

    for e in made:
        await db_session.delete(e)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_a_capped_answer_says_so(db_session):
    """A silent top-N makes a partial answer look complete."""
    agent = await _make_agent(db_session)
    made = [await _make_edge(db_session, agent, dst_addr=f"10.0.0.{i}", comm=f"proc{i}") for i in range(4)]
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/relationships?agent_id={agent.id}&limit=2", headers=_headers(raw))
    body = resp.json()
    assert len(body["groups"]) == 2
    assert body["total_groups"] == 4
    assert body["truncated"] is True

    for e in made:
        await db_session.delete(e)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_raw_returns_the_underlying_edges_capped(db_session):
    """`raw=true` is for the caller that genuinely wants connections rather than relationships — still
    capped, still reporting the total."""
    agent = await _make_agent(db_session)
    made = [await _make_edge(db_session, agent, dst_addr="127.0.0.1", dst_port=40000 + i,
                             comm="kubelet", event_count=10 + i) for i in range(4)]
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/relationships?agent_id={agent.id}&raw=true&limit=2",
                          headers=_headers(raw))
    body = resp.json()
    assert len(body["edges"]) == 2
    assert [e["event_count"] for e in body["edges"]] == [13, 12], "busiest first"
    assert body["total_edges"] == 4
    assert body["truncated"] is True

    for e in made:
        await db_session.delete(e)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(api_token)
    await db_session.commit()
