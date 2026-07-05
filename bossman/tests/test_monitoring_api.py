"""End-to-end tests for the CheckMK-style monitoring REST surface
(bossman/api/monitoring.py + the agents.py groups route) through the real
FastAPI app and real database (see tests/conftest.py's db_session fixture,
and tests/test_agents_api.py for the pattern this mirrors).
"""

import uuid
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from bossman.db.models import Agent, Downtime, Service
from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _make_agent(db_session, **overrides) -> Agent:
    fields = {
        "name": f"mon-api-{uuid.uuid4().hex[:8]}",
        "token": "tok",
        "mode": "standalone",
        "enrollment_state": "enrolled",
        "groups": [],
    }
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _make_service(db_session, agent, **overrides) -> Service:
    now = datetime.now(timezone.utc)
    fields = {
        "agent_id": agent.id,
        "name": "CPU load",
        "metric": "cpu_pct",
        "state": "CRIT",
        "value": 99.0,
        "output": "value 99.0 gt crit threshold 95.0",
        "last_state_change": now,
        "last_checked": now,
        "acknowledged": False,
    }
    fields.update(overrides)
    service = Service(**fields)
    db_session.add(service)
    await db_session.flush()
    await db_session.commit()
    return service


async def _make_api_token(db_session, name="mon-caller"):
    row, raw = new_api_token(name)
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def _cleanup(db_session, agent, *extra):
    for obj in extra:
        got = await db_session.get(type(obj), obj.id)
        if got is not None:
            await db_session.delete(got)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def test_problems_requires_auth(db_session):
    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/problems")
    assert resp.status_code == 401


async def test_list_problems_shows_non_ok_services(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    service = await _make_service(db_session, agent, state="CRIT")

    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/problems", headers=_headers(raw))

    assert resp.status_code == 200
    names = [p["name"] for p in resp.json() if p["agent_id"] == str(agent.id)]
    assert "CPU load" in names

    await db_session.delete(api_token)
    await _cleanup(db_session, agent, service)


async def test_list_problems_excludes_ok_services(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    service = await _make_service(db_session, agent, state="OK", output="fine")

    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/problems", headers=_headers(raw))

    ids = [p["id"] for p in resp.json()]
    assert str(service.id) not in ids

    await db_session.delete(api_token)
    await _cleanup(db_session, agent, service)


async def test_list_problems_filters_by_state_and_host(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    warn_service = await _make_service(db_session, agent, name="Disk space", state="WARN")
    crit_service = await _make_service(db_session, agent, name="CPU load", state="CRIT")

    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/problems", params={"state": "CRIT", "host": agent.name}, headers=_headers(raw))

    names = [p["name"] for p in resp.json()]
    assert names == ["CPU load"]

    await db_session.delete(api_token)
    await _cleanup(db_session, agent, warn_service, crit_service)


async def test_list_problems_excludes_services_in_active_downtime(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    service = await _make_service(db_session, agent)
    now = datetime.now(timezone.utc)
    downtime = Downtime(
        agent_id=agent.id, service_name=service.name, starts_at=now - timedelta(minutes=5), ends_at=now + timedelta(minutes=5), comment="maintenance"
    )
    db_session.add(downtime)
    await db_session.commit()

    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/problems", headers=_headers(raw))
        resp_included = client.get("/api/v1/problems", params={"include_downtime": True}, headers=_headers(raw))

    assert str(service.id) not in [p["id"] for p in resp.json()]
    included_ids = [p["id"] for p in resp_included.json()]
    assert str(service.id) in included_ids
    assert next(p for p in resp_included.json() if p["id"] == str(service.id))["in_downtime"] is True

    await db_session.delete(api_token)
    await db_session.delete(downtime)
    await db_session.flush()
    await _cleanup(db_session, agent, service)


async def test_list_agent_services(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    service = await _make_service(db_session, agent)

    with TestClient(create_app()) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/services", headers=_headers(raw))

    assert resp.status_code == 200
    assert [s["name"] for s in resp.json()] == ["CPU load"]

    await db_session.delete(api_token)
    await _cleanup(db_session, agent, service)


async def test_acknowledge_and_unacknowledge_service(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    service = await _make_service(db_session, agent)

    with TestClient(create_app()) as client:
        ack_resp = client.post(
            f"/api/v1/services/{service.id}/acknowledge", json={"comment": "investigating"}, headers=_headers(raw)
        )
        assert ack_resp.status_code == 200
        assert ack_resp.json()["acknowledged"] is True
        assert ack_resp.json()["ack_comment"] == "investigating"

        unack_resp = client.delete(f"/api/v1/services/{service.id}/acknowledge", headers=_headers(raw))
        assert unack_resp.status_code == 200
        assert unack_resp.json()["acknowledged"] is False
        assert unack_resp.json()["ack_comment"] is None

    await db_session.delete(api_token)
    await _cleanup(db_session, agent, service)


async def test_acknowledge_unknown_service_404(db_session):
    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.post(f"/api/v1/services/{uuid.uuid4()}/acknowledge", json={}, headers=_headers(raw))
    assert resp.status_code == 404
    await db_session.delete(api_token)
    await db_session.commit()


async def test_create_list_and_delete_downtime(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    now = datetime.now(timezone.utc)

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/downtimes",
            json={
                "agent_id": str(agent.id),
                "service_name": None,
                "starts_at": now.isoformat(),
                "ends_at": (now + timedelta(hours=1)).isoformat(),
                "comment": "planned reboot",
            },
            headers=_headers(raw),
        )
        assert create_resp.status_code == 200
        downtime_id = create_resp.json()["id"]

        list_resp = client.get("/api/v1/downtimes", params={"agent_id": str(agent.id)}, headers=_headers(raw))
        assert [d["id"] for d in list_resp.json()] == [downtime_id]

        delete_resp = client.delete(f"/api/v1/downtimes/{downtime_id}", headers=_headers(raw))
        assert delete_resp.status_code == 204

        list_after = client.get("/api/v1/downtimes", params={"agent_id": str(agent.id)}, headers=_headers(raw))
        assert list_after.json() == []

    await db_session.delete(api_token)
    await _cleanup(db_session, agent)


async def test_create_downtime_rejects_ends_before_starts(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    now = datetime.now(timezone.utc)

    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/downtimes",
            json={
                "agent_id": str(agent.id),
                "starts_at": now.isoformat(),
                "ends_at": (now - timedelta(hours=1)).isoformat(),
            },
            headers=_headers(raw),
        )

    assert resp.status_code == 422

    await db_session.delete(api_token)
    await _cleanup(db_session, agent)


async def test_check_rule_crud(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/check-rules",
            json={
                "service_name": "CPU load",
                "metric": "cpu_pct",
                "comparison": "gt",
                "warn_threshold": 80.0,
                "crit_threshold": 95.0,
                "scope_type": "global",
            },
            headers=_headers(raw),
        )
        assert create_resp.status_code == 200
        rule_id = create_resp.json()["id"]

        list_resp = client.get("/api/v1/check-rules", headers=_headers(raw))
        assert rule_id in [r["id"] for r in list_resp.json()]

        update_resp = client.put(
            f"/api/v1/check-rules/{rule_id}",
            json={
                "service_name": "CPU load",
                "metric": "cpu_pct",
                "comparison": "gt",
                "warn_threshold": 70.0,
                "crit_threshold": 90.0,
                "scope_type": "global",
                "enabled": False,
            },
            headers=_headers(raw),
        )
        assert update_resp.status_code == 200
        assert update_resp.json()["warn_threshold"] == 70.0
        assert update_resp.json()["enabled"] is False

        delete_resp = client.delete(f"/api/v1/check-rules/{rule_id}", headers=_headers(raw))
        assert delete_resp.status_code == 204

        list_after = client.get("/api/v1/check-rules", headers=_headers(raw))
        assert rule_id not in [r["id"] for r in list_after.json()]

    await db_session.delete(api_token)
    await db_session.commit()


async def test_check_rule_rejects_invalid_scope(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/check-rules",
            json={
                "service_name": "CPU load",
                "metric": "cpu_pct",
                "comparison": "gt",
                "scope_type": "group",
                "scope_value": None,  # required for scope_type=group
            },
            headers=_headers(raw),
        )

    assert resp.status_code == 422

    await db_session.delete(api_token)
    await db_session.commit()


async def test_check_rule_rejects_invalid_comparison(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/check-rules",
            json={"service_name": "x", "metric": "cpu_pct", "comparison": "bogus", "scope_type": "global"},
            headers=_headers(raw),
        )

    assert resp.status_code == 422

    await db_session.delete(api_token)
    await db_session.commit()


async def test_update_agent_groups(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.patch(
            f"/api/v1/agents/{agent.id}/groups", json={"groups": ["webservers", "prod"]}, headers=_headers(raw)
        )

    assert resp.status_code == 200
    assert resp.json()["groups"] == ["webservers", "prod"]

    await db_session.delete(api_token)
    await _cleanup(db_session, agent)


async def test_fleet_summary(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    ok_service = await _make_service(db_session, agent, name="Disk space", state="OK", output="fine")
    crit_service = await _make_service(db_session, agent, name="CPU load", state="CRIT")

    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/fleet/summary", headers=_headers(raw))

    assert resp.status_code == 200
    body = resp.json()
    assert body["hosts_total"] >= 1
    assert body["services_by_state"]["CRIT"] >= 1
    assert body["services_by_state"]["OK"] >= 1
    assert body["open_problems"] >= 1

    await db_session.delete(api_token)
    await _cleanup(db_session, agent, ok_service, crit_service)
