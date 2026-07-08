"""End-to-end tests for /api/v1/graphs* (Block K11) — real app + real DB
(see tests/conftest.py's db_session fixture).
"""

import uuid
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from bossman.db.models import Agent, Metric
from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _make_agent(db_session, **overrides) -> Agent:
    fields = {"name": f"graph-agent-{uuid.uuid4().hex[:8]}", "token": "tok", "mode": "standalone", "enrollment_state": "enrolled"}
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _make_api_token(db_session):
    row, raw = new_api_token("graph-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def test_graphs_crud(db_session):
    # A separate TestClient block per call (mirrors test_agents_api.py's
    # mass-update tests) — each spins up its own short-lived app lifespan
    # rather than reusing one across several sequential HTTP round-trips.
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/graphs",
            json={
                "name": "Fleet CPU",
                "graph_type": "normal",
                "items": [
                    {"agent_id": str(agent.id), "metric": "cpu_pct", "color": "#ff0000", "draw_style": "line"},
                ],
            },
            headers=_headers(raw),
        )
    assert create_resp.status_code == 200
    body = create_resp.json()
    graph_id = body["id"]
    assert len(body["items"]) == 1
    assert body["items"][0]["metric"] == "cpu_pct"

    with TestClient(create_app()) as client:
        list_resp = client.get("/api/v1/graphs", headers=_headers(raw))
    assert any(g["id"] == graph_id for g in list_resp.json())

    with TestClient(create_app()) as client:
        update_resp = client.put(
            f"/api/v1/graphs/{graph_id}",
            json={
                "name": "Fleet CPU",
                "graph_type": "stacked",
                "items": [
                    {"agent_id": str(agent.id), "metric": "cpu_pct", "color": "#00ff00"},
                    {"agent_id": str(agent.id), "metric": "mem_pct", "color": "#0000ff"},
                ],
            },
            headers=_headers(raw),
        )
    assert update_resp.status_code == 200
    assert update_resp.json()["graph_type"] == "stacked"
    assert len(update_resp.json()["items"]) == 2

    with TestClient(create_app()) as client:
        delete_resp = client.delete(f"/api/v1/graphs/{graph_id}", headers=_headers(raw))
    assert delete_resp.status_code == 204

    with TestClient(create_app()) as client:
        list_after = client.get("/api/v1/graphs", headers=_headers(raw))
    assert not any(g["id"] == graph_id for g in list_after.json())

    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_graphs_duplicate_name_409(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        first = client.post("/api/v1/graphs", json={"name": "dup", "items": []}, headers=_headers(raw))
        assert first.status_code == 200
        second = client.post("/api/v1/graphs", json={"name": "dup", "items": []}, headers=_headers(raw))
        assert second.status_code == 409
        client.delete(f"/api/v1/graphs/{first.json()['id']}", headers=_headers(raw))

    await db_session.delete(api_token)
    await db_session.commit()


async def test_graphs_rejects_invalid_draw_style(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/graphs",
            json={"name": "x", "items": [{"agent_id": str(agent.id), "metric": "cpu_pct", "draw_style": "sparkly"}]},
            headers=_headers(raw),
        )

    assert resp.status_code == 422
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_graph_data_combines_multiple_items(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    now = datetime.now(timezone.utc)
    cpu = Metric(time=now, agent_id=agent.id, metric="cpu_pct", value=42.0, labels={})
    mem = Metric(time=now, agent_id=agent.id, metric="mem_pct", value=63.0, labels={})
    db_session.add_all([cpu, mem])
    await db_session.commit()

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/graphs",
            json={
                "name": "Fleet combo",
                "items": [
                    {"agent_id": str(agent.id), "metric": "cpu_pct"},
                    {"agent_id": str(agent.id), "metric": "mem_pct", "axis_side": "right"},
                ],
            },
            headers=_headers(raw),
        )
    graph_id = create_resp.json()["id"]

    with TestClient(create_app()) as client:
        data_resp = client.get(
            f"/api/v1/graphs/{graph_id}/data",
            params={"since": (now - timedelta(hours=1)).isoformat()},
            headers=_headers(raw),
        )
    assert data_resp.status_code == 200
    body = data_resp.json()
    assert len(body["series"]) == 2
    by_metric = {s["metric"]: s for s in body["series"]}
    assert by_metric["cpu_pct"]["resolution"] == "raw"
    assert by_metric["cpu_pct"]["points"][0]["value"] == 42.0
    assert by_metric["mem_pct"]["axis_side"] == "right"

    with TestClient(create_app()) as client:
        client.delete(f"/api/v1/graphs/{graph_id}", headers=_headers(raw))

    await db_session.delete(api_token)
    await db_session.delete(cpu)
    await db_session.delete(mem)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()
