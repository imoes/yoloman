"""End-to-end tests for /api/v1/plans* through the real FastAPI app and
real database (see tests/conftest.py's db_session fixture). The run route
uses a FakeAgentClient injected via app.dependency_overrides on
get_client_factory — the FastAPI-native version of the client_factory test
seam already used for the poller and the plan engine's own tests.
"""

import uuid

from fastapi.testclient import TestClient
from sqlalchemy import select

from bossman.api.plans import get_client_factory
from bossman.db.models import Agent, PlanRun
from bossman.main import create_app
from bossman.services.auth import new_api_token

MODULE_PLAN = """
name: {plan_name}
description: "test plan"
params:
  message: {{ type: string, required: true }}
steps:
  - name: write_it
    ansible.builtin.copy:
      dest: /etc/motd
      content: "{{{{ message }}}}"
"""


class FakeAgentClient:
    def __init__(self):
        self.tool_calls = []

    async def call_tool(self, name, body):
        self.tool_calls.append((name, body))
        return {"changed": True}

    async def upload_file(self, remote_name, data):
        return {"path": f"/staged/{remote_name}", "bytes_written": len(data)}


async def _make_agent(db_session, **overrides) -> Agent:
    fields = {
        "name": f"plan-agent-{uuid.uuid4().hex[:8]}",
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
    row, raw = new_api_token("plans-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


def _write_plan(tmp_path, plan_name="demo"):
    (tmp_path / f"{plan_name}.yaml").write_text(MODULE_PLAN.format(plan_name=plan_name))


async def test_plans_requires_auth(tmp_path, monkeypatch):
    _write_plan(tmp_path)
    monkeypatch.setenv("BOSSMAN_PLANS_DIR", str(tmp_path))
    app = create_app()

    with TestClient(app) as client:
        resp = client.get("/api/v1/plans")

    assert resp.status_code == 401


async def test_list_and_get_plan(db_session, tmp_path, monkeypatch):
    _write_plan(tmp_path)
    monkeypatch.setenv("BOSSMAN_PLANS_DIR", str(tmp_path))
    api_token, raw = await _make_api_token(db_session)
    app = create_app()

    with TestClient(app) as client:
        list_resp = client.get("/api/v1/plans", headers=_headers(raw))
        detail_resp = client.get("/api/v1/plans/demo", headers=_headers(raw))
        missing_resp = client.get("/api/v1/plans/nonexistent", headers=_headers(raw))

    assert list_resp.status_code == 200
    assert [p["name"] for p in list_resp.json()] == ["demo"]

    assert detail_resp.status_code == 200
    body = detail_resp.json()
    assert body["params"]["message"]["required"] is True
    assert body["steps"][0]["kind"] == "module"
    assert body["steps"][0]["module"] == "copy"

    assert missing_resp.status_code == 404

    await db_session.delete(api_token)
    await db_session.commit()


async def test_reload_plans_regenerates_catalog_cache(db_session, tmp_path, monkeypatch):
    _write_plan(tmp_path)
    monkeypatch.setenv("BOSSMAN_PLANS_DIR", str(tmp_path))
    api_token, raw = await _make_api_token(db_session)
    app = create_app()

    with TestClient(app) as client:
        before_text = app.state.catalog_cache.text
        assert "demo" in before_text

        (tmp_path / "second.yaml").write_text(MODULE_PLAN.format(plan_name="second"))
        # The cache must not pick up the new file until reload is called —
        # that's the whole point of the cache (see services/catalog.py).
        assert app.state.catalog_cache.text == before_text

        resp = client.post("/api/v1/plans/reload", headers=_headers(raw))

        assert resp.status_code == 200
        assert resp.json()["reloaded"] is True
        assert "second" in app.state.catalog_cache.text
        assert app.state.catalog_cache.text != before_text

    await db_session.delete(api_token)
    await db_session.commit()


async def test_reload_plans_requires_auth(tmp_path, monkeypatch):
    _write_plan(tmp_path)
    monkeypatch.setenv("BOSSMAN_PLANS_DIR", str(tmp_path))
    app = create_app()

    with TestClient(app) as client:
        resp = client.post("/api/v1/plans/reload")

    assert resp.status_code == 401


async def test_run_plan_success_with_fake_client(db_session, tmp_path, monkeypatch):
    _write_plan(tmp_path)
    monkeypatch.setenv("BOSSMAN_PLANS_DIR", str(tmp_path))
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    fake = FakeAgentClient()
    app.dependency_overrides[get_client_factory] = lambda: (lambda agent, settings: fake)

    with TestClient(app) as client:
        resp = client.post(
            "/api/v1/plans/demo/run",
            json={"agent": agent.name, "params": {"message": "hi"}},
            headers=_headers(raw),
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "succeeded"
    assert fake.tool_calls == [("copy", {"dest": "/etc/motd", "content": "hi"})]

    plan_run = await db_session.get(PlanRun, body["plan_run_id"])
    assert plan_run is not None
    assert plan_run.requested_by == api_token.name

    await db_session.delete(plan_run)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_run_plan_unknown_agent_404(db_session, tmp_path, monkeypatch):
    _write_plan(tmp_path)
    monkeypatch.setenv("BOSSMAN_PLANS_DIR", str(tmp_path))
    api_token, raw = await _make_api_token(db_session)
    app = create_app()

    with TestClient(app) as client:
        resp = client.post(
            "/api/v1/plans/demo/run",
            json={"agent": "no-such-agent", "params": {"message": "hi"}},
            headers=_headers(raw),
        )

    assert resp.status_code == 404

    await db_session.delete(api_token)
    await db_session.commit()


async def test_run_plan_missing_required_param_422(db_session, tmp_path, monkeypatch):
    _write_plan(tmp_path)
    monkeypatch.setenv("BOSSMAN_PLANS_DIR", str(tmp_path))
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    app.dependency_overrides[get_client_factory] = lambda: (lambda agent, settings: FakeAgentClient())

    with TestClient(app) as client:
        resp = client.post("/api/v1/plans/demo/run", json={"agent": agent.name, "params": {}}, headers=_headers(raw))

    assert resp.status_code == 422

    remaining = (await db_session.scalars(select(PlanRun).where(PlanRun.agent_id == agent.id))).all()
    assert remaining == []

    await db_session.delete(agent)
    await db_session.delete(api_token)
    await db_session.commit()
