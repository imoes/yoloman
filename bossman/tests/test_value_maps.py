"""End-to-end tests for /api/v1/value-maps (Block K4) and the mapped_value
it produces on a materialized Service — real app + real DB (see
tests/conftest.py's db_session fixture).
"""

import uuid
from datetime import datetime, timezone

from fastapi.testclient import TestClient

from bossman.db.models import Agent, CheckRule, Service, ValueMap
from bossman.main import create_app
from bossman.services.auth import new_api_token
from bossman.services.monitoring import to_view


async def _make_agent(db_session, **overrides) -> Agent:
    fields = {"name": f"vm-agent-{uuid.uuid4().hex[:8]}", "token": "tok", "mode": "standalone", "enrollment_state": "enrolled"}
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _make_api_token(db_session):
    row, raw = new_api_token("vm-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def test_value_maps_crud(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/value-maps",
            json={"name": "up-down", "mappings": {"0": "Down", "1": "Up"}},
            headers=_headers(raw),
        )
        assert create_resp.status_code == 200
        vm_id = create_resp.json()["id"]

        list_resp = client.get("/api/v1/value-maps", headers=_headers(raw))
        assert list_resp.status_code == 200
        assert any(v["id"] == vm_id for v in list_resp.json())

        update_resp = client.put(
            f"/api/v1/value-maps/{vm_id}",
            json={"name": "up-down", "mappings": {"0": "Down", "1": "Up", "2": "Unknown"}},
            headers=_headers(raw),
        )
        assert update_resp.status_code == 200
        assert update_resp.json()["mappings"]["2"] == "Unknown"

        delete_resp = client.delete(f"/api/v1/value-maps/{vm_id}", headers=_headers(raw))
        assert delete_resp.status_code == 204

        list_after = client.get("/api/v1/value-maps", headers=_headers(raw))
        assert not any(v["id"] == vm_id for v in list_after.json())

    await db_session.delete(api_token)
    await db_session.commit()


async def test_value_maps_duplicate_name_409(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        first = client.post(
            "/api/v1/value-maps", json={"name": "dup", "mappings": {"0": "a"}}, headers=_headers(raw)
        )
        assert first.status_code == 200
        second = client.post(
            "/api/v1/value-maps", json={"name": "dup", "mappings": {"1": "b"}}, headers=_headers(raw)
        )
        assert second.status_code == 409
        client.delete(f"/api/v1/value-maps/{first.json()['id']}", headers=_headers(raw))

    await db_session.delete(api_token)
    await db_session.commit()


async def test_value_maps_empty_mappings_422(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post("/api/v1/value-maps", json={"name": "empty", "mappings": {}}, headers=_headers(raw))

    assert resp.status_code == 422
    await db_session.delete(api_token)
    await db_session.commit()


async def test_check_rule_with_value_map_maps_service_value(db_session):
    """The core K4 payoff: a Service materialized from a CheckRule with a
    ValueMap attached shows mapped_value alongside its raw numeric value."""
    agent = await _make_agent(db_session)
    value_map = ValueMap(name=f"vm-{uuid.uuid4().hex[:8]}", mappings={"0": "Down", "1": "Up"})
    db_session.add(value_map)
    await db_session.flush()

    rule = CheckRule(
        service_name="Link state",
        metric="link_up",
        comparison="lt",
        warn_threshold=1.0,
        crit_threshold=1.0,
        scope_type="global",
        enabled=True,
        value_map_id=value_map.id,
    )
    db_session.add(rule)
    await db_session.flush()

    now = datetime.now(timezone.utc)
    service = Service(
        agent_id=agent.id,
        name="Link state",
        metric="link_up",
        state="CRIT",
        value=0.0,
        output="link down",
        rule_id=rule.id,
        last_state_change=now,
        last_checked=now,
    )
    db_session.add(service)
    await db_session.commit()

    view = await to_view(db_session, service)
    assert view.mapped_value == "Down"

    await db_session.delete(service)
    await db_session.flush()
    await db_session.delete(rule)
    await db_session.flush()
    await db_session.delete(value_map)
    await db_session.delete(agent)
    await db_session.commit()


async def test_check_rule_without_value_map_has_no_mapped_value(db_session):
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    service = Service(
        agent_id=agent.id,
        name="CPU load",
        metric="cpu_pct",
        state="OK",
        value=42.0,
        output="fine",
        last_state_change=now,
        last_checked=now,
    )
    db_session.add(service)
    await db_session.commit()

    view = await to_view(db_session, service)
    assert view.mapped_value is None

    await db_session.delete(service)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def test_deleting_value_map_detaches_check_rule_not_delete_it(db_session):
    """check_rules.value_map_id is ON DELETE SET NULL — deleting a value
    map must not take rules referencing it down with it."""
    value_map = ValueMap(name=f"vm-{uuid.uuid4().hex[:8]}", mappings={"0": "Down"})
    db_session.add(value_map)
    await db_session.flush()
    rule = CheckRule(
        service_name="Link state",
        metric="link_up",
        comparison="lt",
        warn_threshold=1.0,
        crit_threshold=1.0,
        scope_type="global",
        enabled=True,
        value_map_id=value_map.id,
    )
    db_session.add(rule)
    await db_session.commit()
    rule_id = rule.id

    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.delete(f"/api/v1/value-maps/{value_map.id}", headers=_headers(raw))
    assert resp.status_code == 204

    db_session.expunge_all()
    refreshed_rule = await db_session.get(CheckRule, rule_id)
    assert refreshed_rule is not None
    assert refreshed_rule.value_map_id is None

    await db_session.delete(refreshed_rule)
    await db_session.delete(api_token)
    await db_session.commit()
