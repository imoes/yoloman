"""End-to-end tests for /api/v1/runs* — real HTTP, real Postgres (see
tests/conftest.py's db_session fixture), real API-token auth.
"""

import uuid
from datetime import datetime, timezone

from fastapi.testclient import TestClient

from bossman.db.models import Agent, PlanRun, PlanRunStep
from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _make_agent(db_session) -> Agent:
    agent = Agent(name=f"run-agent-{uuid.uuid4().hex[:8]}", token="tok", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _make_plan_run(db_session, agent, plan_name="demo", status="succeeded") -> PlanRun:
    run = PlanRun(plan_name=plan_name, agent_id=agent.id, params={"message": "hi"}, dry_run=False, status=status)
    db_session.add(run)
    await db_session.flush()
    step = PlanRunStep(
        plan_run_id=run.id,
        step_index=0,
        step_name="write_it",
        module="copy",
        request_body={"dest": "/etc/motd"},
        response_body={"changed": True},
        changed=True,
        http_status=200,
        started_at=datetime.now(timezone.utc),
        finished_at=datetime.now(timezone.utc),
    )
    db_session.add(step)
    await db_session.flush()
    await db_session.commit()
    return run


async def _make_api_token(db_session):
    row, raw = new_api_token("runs-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def _cleanup(db_session, run, agent, api_token):
    got = await db_session.get(PlanRun, run.id)
    if got is not None:
        await db_session.delete(got)
        await db_session.flush()  # cascade-deletes plan_run_steps first
    await db_session.delete(agent)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_runs_requires_auth():
    app = create_app()
    with TestClient(app) as client:
        resp = client.get("/api/v1/runs")
    assert resp.status_code == 401


async def test_list_runs_filtered_by_agent_and_status(db_session):
    agent = await _make_agent(db_session)
    run = await _make_plan_run(db_session, agent)
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/runs?agent_id={agent.id}&status=succeeded", headers=_headers(raw))

    assert resp.status_code == 200
    runs = resp.json()
    assert len(runs) == 1
    assert runs[0]["id"] == str(run.id)
    assert runs[0]["plan_name"] == "demo"

    await _cleanup(db_session, run, agent, api_token)


async def test_list_runs_status_filter_excludes_other_statuses(db_session):
    agent = await _make_agent(db_session)
    run = await _make_plan_run(db_session, agent, status="failed")
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/runs?agent_id={agent.id}&status=succeeded", headers=_headers(raw))

    assert resp.status_code == 200
    assert resp.json() == []

    await _cleanup(db_session, run, agent, api_token)


async def test_get_run_detail_includes_steps(db_session):
    agent = await _make_agent(db_session)
    run = await _make_plan_run(db_session, agent)
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/runs/{run.id}", headers=_headers(raw))

    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "succeeded"
    assert len(body["steps"]) == 1
    assert body["steps"][0]["step_name"] == "write_it"
    assert body["steps"][0]["changed"] is True

    await _cleanup(db_session, run, agent, api_token)


async def test_get_run_404_for_unknown_id(db_session):
    api_token, raw = await _make_api_token(db_session)
    app = create_app()

    with TestClient(app) as client:
        resp = client.get(f"/api/v1/runs/{uuid.uuid4()}", headers=_headers(raw))

    assert resp.status_code == 404

    await db_session.delete(api_token)
    await db_session.commit()
