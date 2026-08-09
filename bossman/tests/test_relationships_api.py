"""End-to-end tests for /api/v1/relationships — real HTTP, real Postgres
(see tests/conftest.py's db_session fixture), real API-token auth.
"""

import uuid
from datetime import datetime, timezone

from fastapi.testclient import TestClient

from bossman.db.models import Agent, HostEdge
from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _make_agent(db_session) -> Agent:
    agent = Agent(name=f"rel-agent-{uuid.uuid4().hex[:8]}", token="tok", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _make_edge(db_session, agent, dst_addr="9.9.9.9", dst_port=443) -> HostEdge:
    now = datetime.now(timezone.utc)
    edge = HostEdge(
        src_agent_id=agent.id,
        src_comm="curl",
        dst_addr=dst_addr,
        dst_port=dst_port,
        event_count=5,
        first_seen_at=now,
        last_seen_at=now,
        latency_ms_p50=1.5,
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
    edges = resp.json()
    assert len(edges) == 1
    assert edges[0]["dst_addr"] == "1.1.1.1"
    assert edges[0]["event_count"] == 5
    assert edges[0]["latency_ms_p50"] == 1.5

    await db_session.delete(edge_a)
    await db_session.delete(edge_b)
    await db_session.flush()
    await db_session.delete(agent_a)
    await db_session.delete(agent_b)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_list_relationships_unfiltered_returns_all(db_session):
    agent = await _make_agent(db_session)
    edge = await _make_edge(db_session, agent)
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    with TestClient(app) as client:
        resp = client.get("/api/v1/relationships", headers=_headers(raw))

    assert resp.status_code == 200
    assert any(e["src_agent_id"] == str(agent.id) for e in resp.json())

    await db_session.delete(edge)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(api_token)
    await db_session.commit()
