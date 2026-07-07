"""End-to-end tests for GET /api/v1/agents/{id}/processes — the on-demand
proxy to an agent's live process table (Block J1). A FakeAgentClient is
injected via app.dependency_overrides on get_client_factory, the same test
seam the plan-run route uses, so no real agent connection is made.
"""

import uuid

from fastapi.testclient import TestClient

from bossman.api.plans import get_client_factory
from bossman.db.models import Agent
from bossman.main import create_app
from bossman.services.agent_client import AgentClientError
from bossman.services.auth import new_api_token


class FakeAgentClient:
    def __init__(self, payload=None, raises: bool = False):
        self.payload = payload or {
            "processes": [
                {"pid": 1, "ppid": 0, "user": "root", "uid": 0, "comm": "systemd",
                 "command": "/sbin/init", "state": "S", "cpu_percent": 0.5,
                 "rss_kib": 10240, "num_threads": 1, "container_id": "",
                 "connections": []},
            ],
            "count": 1,
            "sample_window_ms": 200,
        }
        self.raises = raises
        self.calls: list[int] = []

    async def processes(self, limit: int = 0):
        self.calls.append(limit)
        if self.raises:
            raise AgentClientError("10.0.0.9:8010: request failed: connection refused")
        return self.payload


async def _make_agent(db_session, **overrides) -> Agent:
    fields = {
        "name": f"proc-agent-{uuid.uuid4().hex[:8]}",
        "token": "tok",
        "address": "10.0.0.9:8010",
        "mode": "standalone",
        "enrollment_state": "enrolled",
    }
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _make_api_token(db_session):
    row, raw = new_api_token("proc-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def test_processes_requires_auth(db_session):
    agent = await _make_agent(db_session)
    with TestClient(create_app()) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/processes")
    assert resp.status_code == 401
    await db_session.delete(agent)
    await db_session.commit()


async def test_processes_proxies_agent_payload(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    fake = FakeAgentClient()
    app.dependency_overrides[get_client_factory] = lambda: (lambda agent, settings: fake)

    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/processes", params={"limit": 5}, headers=_headers(raw))

    assert resp.status_code == 200
    body = resp.json()
    assert body["count"] == 1
    assert body["processes"][0]["comm"] == "systemd"
    assert fake.calls == [5]  # limit forwarded to the agent

    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_processes_unknown_agent_404(db_session):
    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.get(f"/api/v1/agents/{uuid.uuid4()}/processes", headers=_headers(raw))
    assert resp.status_code == 404
    await db_session.delete(api_token)
    await db_session.commit()


async def test_processes_no_address_422(db_session):
    agent = await _make_agent(db_session, address=None)
    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/processes", headers=_headers(raw))
    assert resp.status_code == 422
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_processes_unreachable_agent_502(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    fake = FakeAgentClient(raises=True)
    app.dependency_overrides[get_client_factory] = lambda: (lambda agent, settings: fake)

    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/processes", headers=_headers(raw))

    assert resp.status_code == 502

    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()
