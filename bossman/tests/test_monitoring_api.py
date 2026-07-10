"""End-to-end tests for the CheckMK-style monitoring REST surface
(bossman/api/monitoring.py + the agents.py groups route) through the real
FastAPI app and real database (see tests/conftest.py's db_session fixture,
and tests/test_agents_api.py for the pattern this mirrors).
"""

import uuid
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient
from sqlalchemy import select

from bossman.db.models import Agent, Downtime, Metric, Service, ServiceStateHistory
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
    # Block M: not testing the host ACL here — a wildcard grant keeps this
    # token past require_manage_agent on the per-host management routes.
    from bossman.db.models import AccessGrant

    db_session.add(AccessGrant(subject_kind="api_token", subject_ref=name, scope="all"))
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


async def test_list_problems_filters_by_tag(db_session):
    """Block K7: GET /api/v1/problems?tag= filters by the problem host's
    Agent.tags — 'name' matches any value, 'name:value' requires an exact
    match."""
    prod_agent = await _make_agent(db_session, tags={"env": "prod"})
    staging_agent = await _make_agent(db_session, tags={"env": "staging"})
    api_token, raw = await _make_api_token(db_session)
    prod_service = await _make_service(db_session, prod_agent, name="CPU load", state="CRIT")
    staging_service = await _make_service(db_session, staging_agent, name="CPU load", state="CRIT")

    with TestClient(create_app()) as client:
        exact_resp = client.get("/api/v1/problems", params={"tag": "env:prod"}, headers=_headers(raw))
        any_value_resp = client.get("/api/v1/problems", params={"tag": "env"}, headers=_headers(raw))
        no_match_resp = client.get("/api/v1/problems", params={"tag": "env:qa"}, headers=_headers(raw))

    assert [p["id"] for p in exact_resp.json()] == [str(prod_service.id)]
    assert {p["id"] for p in any_value_resp.json()} == {str(prod_service.id), str(staging_service.id)}
    assert no_match_resp.json() == []

    await db_session.delete(api_token)
    await _cleanup(db_session, prod_agent, prod_service)
    await _cleanup(db_session, staging_agent, staging_service)


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


async def test_delete_check_rule_with_owned_services(db_session):
    """Deleting a rule that already materialized services must not 500 on
    the services.rule_id FK (Block H6/H7 fix): its owned services are
    removed with it."""
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    app = create_app()
    with TestClient(app) as client:
        created = client.post(
            "/api/v1/check-rules",
            json={"service_name": "Mem", "metric": "mem_used_pct", "comparison": "ge",
                  "warn_threshold": 80.0, "crit_threshold": 90.0, "scope_type": "global"},
            headers=_headers(raw),
        )
        rule_id = created.json()["id"]

    # A service materialized by that rule (as evaluate_host would create).
    svc = await _make_service(db_session, agent, name="Mem", metric="mem_used_pct")
    svc.rule_id = uuid.UUID(rule_id)
    await db_session.commit()

    with TestClient(app) as client:
        resp = client.delete(f"/api/v1/check-rules/{rule_id}", headers=_headers(raw))
        assert resp.status_code == 204, resp.text

    # The route deleted the service in its own session; drop db_session's
    # cached copies so this reads the real current rows (a fresh query).
    svc_id = svc.id
    db_session.expunge_all()
    gone = await db_session.scalar(select(Service).where(Service.id == svc_id))
    assert gone is None, "the rule's owned service is removed with it"

    await db_session.delete(api_token)
    await db_session.flush()
    await _cleanup(db_session, agent)


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


async def test_check_rule_composite_condition_create_and_roundtrip(db_session):
    """Block K9: a composite CheckRule's extra_conditions/condition_logic
    round-trip through create + list."""
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/check-rules",
            json={
                "service_name": "Overloaded",
                "metric": "cpu_pct",
                "comparison": "gt",
                "warn_threshold": 80.0,
                "crit_threshold": 95.0,
                "scope_type": "global",
                "extra_conditions": [{"metric": "load1", "comparison": "gt", "crit_threshold": 8.0}],
                "condition_logic": "OR",
            },
            headers=_headers(raw),
        )
        assert create_resp.status_code == 200
        body = create_resp.json()
        assert body["condition_logic"] == "OR"
        assert body["extra_conditions"] == [{"metric": "load1", "comparison": "gt", "crit_threshold": 8.0}]

        client.delete(f"/api/v1/check-rules/{body['id']}", headers=_headers(raw))

    await db_session.delete(api_token)
    await db_session.commit()


async def test_check_rule_rejects_invalid_condition_logic(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/check-rules",
            json={
                "service_name": "x", "metric": "cpu_pct", "comparison": "gt", "scope_type": "global",
                "condition_logic": "XOR",
            },
            headers=_headers(raw),
        )

    assert resp.status_code == 422
    await db_session.delete(api_token)
    await db_session.commit()


async def test_check_rule_rejects_malformed_extra_condition(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/check-rules",
            json={
                "service_name": "x", "metric": "cpu_pct", "comparison": "gt", "scope_type": "global",
                "extra_conditions": [{"metric": "load1"}],  # missing "comparison"
            },
            headers=_headers(raw),
        )

    assert resp.status_code == 422
    await db_session.delete(api_token)
    await db_session.commit()


async def test_get_service_history_returns_newest_first(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    now = datetime.now(timezone.utc)
    older = ServiceStateHistory(time=now - timedelta(minutes=5), agent_id=agent.id, service_name="CPU load", state="OK", value=10.0)
    newer = ServiceStateHistory(time=now, agent_id=agent.id, service_name="CPU load", state="CRIT", value=99.0)
    db_session.add_all([older, newer])
    await db_session.commit()

    with TestClient(create_app()) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/services/CPU%20load/history", headers=_headers(raw))

    assert resp.status_code == 200
    body = resp.json()
    assert [p["state"] for p in body] == ["CRIT", "OK"]

    await db_session.delete(api_token)
    await db_session.delete(older)
    await db_session.delete(newer)
    await db_session.flush()
    await _cleanup(db_session, agent)


async def test_get_service_history_name_with_slash(db_session):
    # Agent-reported disk checks are named "Disk /usr" etc.; the slash must
    # survive routing (the {service_name:path} converter) instead of 404ing.
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    now = datetime.now(timezone.utc)
    hist = ServiceStateHistory(time=now, agent_id=agent.id, service_name="Disk /usr", state="OK", value=33.5)
    db_session.add(hist)
    await db_session.commit()

    with TestClient(create_app()) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/services/Disk%20%2Fusr/history", headers=_headers(raw))

    assert resp.status_code == 200
    assert [p["state"] for p in resp.json()] == ["OK"]

    await db_session.delete(api_token)
    await db_session.delete(hist)
    await db_session.flush()
    await _cleanup(db_session, agent)


async def test_get_service_availability_report(db_session):
    """Block H9: the availability endpoint splits time-in-state over a
    look-back window (here 4h, CRIT for the last hour → ok_percent≈75)."""
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    now = datetime.now(timezone.utc)
    ok = ServiceStateHistory(time=now - timedelta(hours=4), agent_id=agent.id, service_name="CPU load", state="OK", value=10.0)
    crit = ServiceStateHistory(time=now - timedelta(hours=1), agent_id=agent.id, service_name="CPU load", state="CRIT", value=99.0)
    db_session.add_all([ok, crit])
    await db_session.commit()

    with TestClient(create_app()) as client:
        resp = client.get(
            f"/api/v1/agents/{agent.id}/services/CPU%20load/availability",
            params={"hours": 4},
            headers=_headers(raw),
        )

    assert resp.status_code == 200
    body = resp.json()
    assert abs(body["ok_percent"] - 75.0) < 0.5
    by_state = {s["state"]: s["percent"] for s in body["slices"]}
    assert abs(by_state["CRIT"] - 25.0) < 0.5
    # The OK row sits on the window's left edge; depending on sub-second
    # request timing it counts either as an in-window change or as carry-in
    # — either way the percentages above hold.
    assert body["state_changes"] >= 1

    await db_session.delete(api_token)
    await db_session.delete(ok)
    await db_session.delete(crit)
    await db_session.flush()
    await _cleanup(db_session, agent)


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


async def test_fleet_hosts_reports_real_metric_values_and_state_rollup(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    warn_service = await _make_service(db_session, agent, name="Disk /", state="WARN")
    now = datetime.now(timezone.utc)
    metrics = [
        Metric(time=now, agent_id=agent.id, metric="cpu_load1", value=0.42, labels={}),
        Metric(time=now, agent_id=agent.id, metric="mem_used_pct", value=55.5, labels={}),
        # Real timestamps would differ by microseconds here too (see
        # poller._disambiguate_colliding_timestamps) since Metric's
        # primary key is (time, agent_id, metric), not including labels —
        # this test seeds rows directly via the ORM, so it must stagger
        # them itself to avoid a duplicate-key error on insert.
        Metric(time=now, agent_id=agent.id, metric="disk_used_pct", value=30.0, labels={"mount": "/"}),
        Metric(time=now + timedelta(microseconds=1), agent_id=agent.id, metric="disk_used_pct", value=91.2, labels={"mount": "/data"}),
    ]
    db_session.add_all(metrics)
    await db_session.commit()

    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/fleet/hosts", headers=_headers(raw))

    assert resp.status_code == 200
    host = next(h for h in resp.json() if h["id"] == str(agent.id))
    assert host["cpu_load"] == 0.42
    assert host["mem_used_pct"] == 55.5
    assert host["disk_used_pct_max"] == 91.2, "the worst (highest) mount must win, not an arbitrary one"
    assert host["state_rollup"] == "WARN"
    assert host["service_counts"]["WARN"] == 1
    assert host["parent_agent_id"] is None

    await db_session.delete(api_token)
    for m in metrics:
        await db_session.delete(m)
    await db_session.flush()
    await _cleanup(db_session, agent, warn_service)


async def test_fleet_hosts_shows_satellite_with_parent_link(db_session):
    proxy = await _make_agent(db_session, mode="proxy")
    api_token, raw = await _make_api_token(db_session)
    satellite = Agent(
        name=f"sat-{uuid.uuid4().hex[:8]}",
        token="",
        mode="satellite",
        enrollment_state="enrolled",
        agent_metadata={},
        parent_agent_id=proxy.id,
    )
    db_session.add(satellite)
    await db_session.commit()

    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/fleet/hosts", headers=_headers(raw))

    assert resp.status_code == 200
    sat_out = next(h for h in resp.json() if h["id"] == str(satellite.id))
    assert sat_out["parent_agent_id"] == str(proxy.id)
    assert sat_out["parent_name"] == proxy.name
    assert sat_out["mode"] == "satellite"
    assert sat_out["state_rollup"] == "OK", "a satellite with no services yet should roll up to OK, not crash"

    await db_session.delete(api_token)
    await db_session.delete(satellite)
    await db_session.flush()
    await db_session.delete(proxy)
    await db_session.commit()
