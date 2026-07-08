"""End-to-end tests for /api/v1/agents* through the real FastAPI app and
real database (see tests/conftest.py's db_session fixture) — real HTTP,
real Postgres, a real API token for auth (the machine-caller path
services/auth.py already covers on its own; here it's just the credential
used to reach these routes).
"""

import uuid
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import select

from bossman.api.plans import get_client_factory
from bossman.db.models import Agent, Metric
from bossman.main import create_app
from bossman.services.auth import new_api_token


class FakeAgentClient:
    def __init__(self):
        self.metrics_calls: list = []

    async def metrics_dump(self, from_):
        self.metrics_calls.append(from_)
        return {}

    async def connections_dump(self, since):
        return []

    async def hosts_overview(self):
        return []


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
    assert body["resolution"] == "raw"

    await _cleanup(db_session, agent=agent, api_token=api_token, metrics=[metric])


async def test_agent_metrics_since_beyond_raw_retention_reports_downsampled_resolution(db_session):
    """Block K1b: a `since` older than settings.metrics_retention_days
    reports resolution="hourly" (or "daily") even if the continuous
    aggregate has nothing materialized yet for this brand-new agent — the
    route must not silently fall back to raw and pretend nothing changed."""
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    since = (datetime.now(timezone.utc) - timedelta(days=40)).isoformat()

    with TestClient(create_app()) as client:
        resp = client.get(
            f"/api/v1/agents/{agent.id}/metrics",
            params={"metric": "cpu_pct", "since": since},
            headers=_headers(raw),
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["resolution"] == "hourly"
    assert body["points"] == []  # nothing materialized for this fresh agent, but the tier choice is still correct

    await _cleanup(db_session, agent=agent, api_token=api_token, metrics=[])


async def test_agent_metrics_latest_returns_newest_per_metric(db_session):
    agent = await _make_agent(db_session)
    t0 = datetime.now(timezone.utc)
    older = Metric(time=t0 - timedelta(minutes=5), agent_id=agent.id, metric="cpu_pct", value=10.0, labels={})
    newer = Metric(time=t0, agent_id=agent.id, metric="cpu_pct", value=42.5, labels={"core": "0"})
    other = Metric(time=t0 - timedelta(minutes=1), agent_id=agent.id, metric="mem_pct", value=63.0, labels={})
    db_session.add_all([older, newer, other])
    await db_session.flush()
    await db_session.commit()
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/metrics/latest", headers=_headers(raw))

    assert resp.status_code == 200
    metrics = {m["metric"]: m for m in resp.json()["metrics"]}
    # One row per metric name, and cpu_pct is its *newest* sample, not the older one.
    assert set(metrics) == {"cpu_pct", "mem_pct"}
    assert metrics["cpu_pct"]["value"] == 42.5
    assert metrics["cpu_pct"]["labels"] == {"core": "0"}
    assert metrics["mem_pct"]["value"] == 63.0

    await _cleanup(db_session, agent=agent, api_token=api_token, metrics=[older, newer, other])


async def test_mass_update_groups_add_replace_remove(db_session):
    """Block K2c ("Mass update"): bulk-edit host-group membership across
    many agents in one call."""
    a1 = await _make_agent(db_session, groups=["Europe"])
    a2 = await _make_agent(db_session, groups=["Europe", "web"])
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        add_resp = client.post(
            "/api/v1/agents/mass-update/groups",
            json={"agent_ids": [str(a1.id), str(a2.id)], "op": "add", "groups": ["prod"]},
            headers=_headers(raw),
        )
    assert add_resp.status_code == 200
    by_id = {a["id"]: a for a in add_resp.json()}
    assert sorted(by_id[str(a1.id)]["groups"]) == ["Europe", "prod"]
    assert sorted(by_id[str(a2.id)]["groups"]) == ["Europe", "prod", "web"]

    with TestClient(create_app()) as client:
        remove_resp = client.post(
            "/api/v1/agents/mass-update/groups",
            json={"agent_ids": [str(a1.id), str(a2.id)], "op": "remove", "groups": ["Europe"]},
            headers=_headers(raw),
        )
    by_id = {a["id"]: a for a in remove_resp.json()}
    assert sorted(by_id[str(a1.id)]["groups"]) == ["prod"]
    assert sorted(by_id[str(a2.id)]["groups"]) == ["prod", "web"]

    with TestClient(create_app()) as client:
        replace_resp = client.post(
            "/api/v1/agents/mass-update/groups",
            json={"agent_ids": [str(a1.id)], "op": "replace", "groups": ["staging"]},
            headers=_headers(raw),
        )
    assert replace_resp.json()[0]["groups"] == ["staging"]

    await _cleanup(db_session, agent=a1, api_token=api_token)
    await _cleanup(db_session, agent=a2)


async def test_mass_update_groups_unknown_agent_404(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/agents/mass-update/groups",
            json={"agent_ids": [str(uuid.uuid4())], "op": "add", "groups": ["x"]},
            headers=_headers(raw),
        )

    assert resp.status_code == 404
    await _cleanup(db_session, api_token=api_token)


async def test_mass_update_groups_invalid_op_422(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/agents/mass-update/groups",
            json={"agent_ids": [str(agent.id)], "op": "frobnicate", "groups": ["x"]},
            headers=_headers(raw),
        )

    assert resp.status_code == 422
    await _cleanup(db_session, agent=agent, api_token=api_token)


async def test_update_agent_tags(db_session):
    """Block K7 (tagging): PATCH /api/v1/agents/{id}/tags replaces the
    whole dict, matching update_agent_groups's replace-not-diff shape."""
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.patch(
            f"/api/v1/agents/{agent.id}/tags",
            json={"tags": {"env": "prod", "critical": ""}},
            headers=_headers(raw),
        )

    assert resp.status_code == 200
    assert resp.json()["tags"] == {"env": "prod", "critical": ""}

    await _cleanup(db_session, agent=agent, api_token=api_token)


async def test_poll_agent_now_triggers_immediate_poll(db_session):
    """Block K5 ("Execute now"): forces poll_agent to run immediately via
    a FakeAgentClient injected through the same get_client_factory seam
    the plan-run route uses — no real network call."""
    agent = await _make_agent(db_session, address="10.0.0.9:8010")
    api_token, raw = await _make_api_token(db_session)

    app = create_app()
    fake = FakeAgentClient()
    app.dependency_overrides[get_client_factory] = lambda: (lambda agent, settings: fake)

    with TestClient(app) as client:
        resp = client.post(f"/api/v1/agents/{agent.id}/poll-now", headers=_headers(raw))

    assert resp.status_code == 200
    body = resp.json()
    assert body["agent_id"] == str(agent.id)
    assert body["errors"] == []
    assert fake.metrics_calls == [None]  # first poll ever for this agent -> no cursor yet

    await _cleanup(db_session, agent=agent, api_token=api_token)


async def test_poll_agent_now_unknown_agent_404(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post(f"/api/v1/agents/{uuid.uuid4()}/poll-now", headers=_headers(raw))

    assert resp.status_code == 404
    await _cleanup(db_session, api_token=api_token)


async def test_delete_agent_removes_host_and_children(db_session):
    from bossman.db.models import Service

    agent = await _make_agent(db_session, address="10.0.0.9:8010")
    # A child row in a NO-ACTION (non-cascading) table, to prove the endpoint
    # clears it rather than hitting an FK violation.
    svc = Service(agent_id=agent.id, name="CPU load", metric="cpu_load5", state="OK")
    db_session.add(svc)
    await db_session.commit()
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.delete(f"/api/v1/agents/{agent.id}", headers=_headers(raw))
    assert resp.status_code == 204

    # The app committed on its own session; drop this test session's identity-
    # map cache (expunge, not expire — expire would trigger a lazy reload of
    # the deleted row and MissingGreenlet) so the re-fetch actually hits the DB.
    db_session.expunge_all()
    assert await db_session.scalar(select(Agent).where(Agent.id == agent.id)) is None
    left = await db_session.scalar(select(Service).where(Service.agent_id == agent.id))
    assert left is None

    await _cleanup(db_session, api_token=api_token)


async def test_delete_agent_orphans_satellites(db_session):
    proxy = await _make_agent(db_session, mode="proxy", address="10.0.0.1:8010")
    sat = await _make_agent(db_session, mode="satellite", parent_agent_id=proxy.id)
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.delete(f"/api/v1/agents/{proxy.id}", headers=_headers(raw))
    assert resp.status_code == 204

    # The satellite survives, orphaned (parent_agent_id cleared) — deleting a
    # proxy must not delete the hosts it was relaying.
    await db_session.refresh(sat)
    assert sat.parent_agent_id is None

    await _cleanup(db_session, agent=sat, api_token=api_token)


async def test_delete_agent_unknown_404(db_session):
    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.delete(f"/api/v1/agents/{uuid.uuid4()}", headers=_headers(raw))
    assert resp.status_code == 404
    await _cleanup(db_session, api_token=api_token)


async def test_dns_name_falls_back_to_inventory_hostname(db_session):
    # No address (a satellite) but an inventory hostname → dns_name resolves
    # to the hostname, not blank.
    sat = await _make_agent(
        db_session, mode="satellite", address=None,
        facts={"os": {"hostname": "host1.example.internal"}},
    )
    # An addressed host → dns_name is the host part, port stripped.
    addressed = await _make_agent(db_session, address="host2.example.internal:18051")
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        sat_body = client.get(f"/api/v1/agents/{sat.id}", headers=_headers(raw)).json()
        addr_body = client.get(f"/api/v1/agents/{addressed.id}", headers=_headers(raw)).json()

    assert sat_body["dns_name"] == "host1.example.internal"
    assert addr_body["dns_name"] == "host2.example.internal"

    await _cleanup(db_session, agent=sat, api_token=api_token)
    await _cleanup(db_session, agent=addressed)
