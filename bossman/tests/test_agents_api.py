"""End-to-end tests for /api/v1/agents* through the real FastAPI app and
real database (see tests/conftest.py's db_session fixture) — real HTTP,
real Postgres, a real API token for auth (the machine-caller path
services/auth.py already covers on its own; here it's just the credential
used to reach these routes).
"""

import uuid
from datetime import datetime, timezone

from fastapi.testclient import TestClient

from bossman.db.models import Agent, Metric
from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _make_agent(db_session, **overrides) -> Agent:
    fields = {
        "name": f"api-agent-{uuid.uuid4().hex[:8]}",
        "token": "tok",
        "mode": "standalone",
        "enrollment_state": "enrolled",
    }
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _make_api_token(db_session, name="test-caller"):
    row, raw = new_api_token(name)
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw_token):
    return {"Authorization": f"Bearer {raw_token}"}


async def _cleanup(db_session, agent=None, api_token=None, metrics=None):
    for m in metrics or []:
        got = await db_session.get(Metric, {"time": m.time, "agent_id": m.agent_id, "metric": m.metric})
        if got is not None:
            await db_session.delete(got)
    await db_session.flush()
    if agent is not None:
        await db_session.delete(agent)
    if api_token is not None:
        await db_session.delete(api_token)
    await db_session.commit()


async def test_list_agents_requires_auth():
    app = create_app()
    with TestClient(app) as client:
        resp = client.get("/api/v1/agents")
    assert resp.status_code == 401


async def test_list_and_get_agent(db_session):
    agent = await _make_agent(db_session, address="10.0.0.5:8010")
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    with TestClient(app) as client:
        list_resp = client.get("/api/v1/agents", headers=_headers(raw))
        get_resp = client.get(f"/api/v1/agents/{agent.id}", headers=_headers(raw))

    assert list_resp.status_code == 200
    assert any(a["name"] == agent.name for a in list_resp.json())

    assert get_resp.status_code == 200
    body = get_resp.json()
    assert body["name"] == agent.name
    assert body["address"] == "10.0.0.5:8010"

    await _cleanup(db_session, agent=agent, api_token=api_token)


async def test_get_agent_404_for_unknown_id(db_session):
    api_token, raw = await _make_api_token(db_session)
    app = create_app()

    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{uuid.uuid4()}", headers=_headers(raw))

    assert resp.status_code == 404

    await _cleanup(db_session, api_token=api_token)


async def test_agent_metrics_catalog_discovery(db_session):
    agent = await _make_agent(db_session)
    m1 = Metric(time=datetime.now(timezone.utc), agent_id=agent.id, metric="cpu_pct", value=1.0, labels={})
    m2 = Metric(time=datetime.now(timezone.utc), agent_id=agent.id, metric="mem_pct", value=2.0, labels={})
    db_session.add_all([m1, m2])
    await db_session.flush()
    await db_session.commit()
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/metrics", headers=_headers(raw))

    assert resp.status_code == 200
    assert sorted(resp.json()["metrics"]) == ["cpu_pct", "mem_pct"]

    await _cleanup(db_session, agent=agent, api_token=api_token, metrics=[m1, m2])


async def test_agent_metrics_with_metric_filter_returns_points(db_session):
    agent = await _make_agent(db_session)
    point_time = datetime.now(timezone.utc)
    metric = Metric(time=point_time, agent_id=agent.id, metric="cpu_pct", value=42.5, labels={"core": "0"})
    db_session.add(metric)
    await db_session.flush()
    await db_session.commit()
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/metrics?metric=cpu_pct", headers=_headers(raw))

    assert resp.status_code == 200
    body = resp.json()
    assert body["metric"] == "cpu_pct"
    assert len(body["points"]) == 1
    assert body["points"][0]["value"] == 42.5
    assert body["points"][0]["labels"] == {"core": "0"}

    await _cleanup(db_session, agent=agent, api_token=api_token, metrics=[metric])
