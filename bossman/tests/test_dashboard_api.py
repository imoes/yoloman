"""End-to-end tests for the per-operator GridStack dashboard REST surface
(bossman/api/dashboard.py) through the real FastAPI app and real database
— mirrors tests/test_monitoring_api.py's pattern.
"""

import uuid

from fastapi.testclient import TestClient

from bossman.db.models import Agent, Service
from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _make_api_token(db_session, name="dash-caller"):
    row, raw = new_api_token(name)
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def test_dashboard_widgets_requires_auth(db_session):
    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/dashboard-widgets")
    assert resp.status_code == 401


async def test_create_list_update_delete_widget(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/dashboard-widgets",
            json={"widget_type": "stat", "title": "Open problems", "config": {"stat_source": "open_problems"}},
            headers=_headers(raw),
        )
        assert create_resp.status_code == 200
        widget = create_resp.json()
        assert widget["widget_type"] == "stat"
        # DEFAULT_SIZE["stat"] = (2, 2) — confirms the default-geometry path
        assert widget["gs_w"] == 2
        assert widget["gs_h"] == 2
        widget_id = widget["id"]

        list_resp = client.get("/api/v1/dashboard-widgets", headers=_headers(raw))
        assert widget_id in [w["id"] for w in list_resp.json()]

        update_resp = client.patch(
            f"/api/v1/dashboard-widgets/{widget_id}",
            json={"gs_x": 4, "gs_y": 2, "title": "Renamed"},
            headers=_headers(raw),
        )
        assert update_resp.status_code == 200
        assert update_resp.json()["gs_x"] == 4
        assert update_resp.json()["title"] == "Renamed"

        delete_resp = client.delete(f"/api/v1/dashboard-widgets/{widget_id}", headers=_headers(raw))
        assert delete_resp.status_code == 204

        list_after = client.get("/api/v1/dashboard-widgets", headers=_headers(raw))
        assert widget_id not in [w["id"] for w in list_after.json()]

    await db_session.delete(api_token)
    await db_session.commit()


async def test_create_widget_rejects_unknown_type(db_session):
    """The type is derived from the real list, not hardcoded.

    This used to post "war_room" as its example of an unknown type — and then war_room became
    a supported widget, so the test was asserting that a VALID type gets rejected. Asking the
    source of truth for a name it does not contain cannot rot that way.
    """
    from bossman.services.dashboard import WIDGET_TYPES_ALL

    unknown = "definitely_not_a_widget"
    assert unknown not in WIDGET_TYPES_ALL, "pick a name the backend really does not know"
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/dashboard-widgets",
            json={"widget_type": unknown, "title": "x"},
            headers=_headers(raw),
        )

    assert resp.status_code == 422

    await db_session.delete(api_token)
    await db_session.commit()


async def test_widgets_are_scoped_to_the_calling_identity(db_session):
    token_a, raw_a = await _make_api_token(db_session, name="dash-a")
    token_b, raw_b = await _make_api_token(db_session, name="dash-b")

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/dashboard-widgets",
            json={"widget_type": "stat", "title": "mine"},
            headers=_headers(raw_a),
        )
        widget_id = create_resp.json()["id"]

        # caller B must not see caller A's widget in its own list...
        list_b = client.get("/api/v1/dashboard-widgets", headers=_headers(raw_b))
        assert widget_id not in [w["id"] for w in list_b.json()]

        # ...nor be able to update or delete it.
        update_b = client.patch(f"/api/v1/dashboard-widgets/{widget_id}", json={"title": "hijacked"}, headers=_headers(raw_b))
        assert update_b.status_code == 404
        delete_b = client.delete(f"/api/v1/dashboard-widgets/{widget_id}", headers=_headers(raw_b))
        assert delete_b.status_code == 404

        client.delete(f"/api/v1/dashboard-widgets/{widget_id}", headers=_headers(raw_a))

    await db_session.delete(token_a)
    await db_session.delete(token_b)
    await db_session.commit()


async def test_widget_data_stat_reports_real_open_problems_count(db_session):
    api_token, raw = await _make_api_token(db_session)
    agent = Agent(name=f"dash-agent-{uuid.uuid4().hex[:8]}", token="tok", mode="standalone", enrollment_state="enrolled", agent_metadata={})
    db_session.add(agent)
    await db_session.flush()
    service = Service(agent_id=agent.id, name="Disk /", metric="disk_used_pct", state="CRIT", output="95% used")
    db_session.add(service)
    await db_session.commit()

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/dashboard-widgets",
            json={"widget_type": "stat", "title": "Open problems", "config": {"stat_source": "open_problems"}},
            headers=_headers(raw),
        )
        widget_id = create_resp.json()["id"]

        data_resp = client.get(f"/api/v1/dashboard-widgets/{widget_id}/data", headers=_headers(raw))
        assert data_resp.status_code == 200
        assert data_resp.json()["value"] >= 1

        client.delete(f"/api/v1/dashboard-widgets/{widget_id}", headers=_headers(raw))

    await db_session.delete(api_token)
    await db_session.delete(service)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def test_widget_data_top_hosts_reports_real_host(db_session):
    """The widget must report REAL fleet hosts, not a stub.

    The limit is set explicitly because it defaults to 10 and this database shares a fleet of
    ~200 agents — a freshly created host cannot be in the first ten, so the test used to depend
    on the fleet being small. Raising it keeps the actual claim (real data, from fleet_hosts)
    without depending on how many hosts happen to exist.
    """
    api_token, raw = await _make_api_token(db_session)
    agent = Agent(name=f"dash-agent-{uuid.uuid4().hex[:8]}", token="tok", mode="standalone", enrollment_state="enrolled", agent_metadata={})
    db_session.add(agent)
    await db_session.commit()

    with TestClient(create_app()) as client:
        create_resp = client.post(
            "/api/v1/dashboard-widgets",
            json={"widget_type": "top_hosts", "title": "Hosts", "config": {"limit": 1000}},
            headers=_headers(raw),
        )
        widget_id = create_resp.json()["id"]

        data_resp = client.get(f"/api/v1/dashboard-widgets/{widget_id}/data", headers=_headers(raw))
        assert data_resp.status_code == 200
        assert any(h["name"] == agent.name for h in data_resp.json()["hosts"])

        client.delete(f"/api/v1/dashboard-widgets/{widget_id}", headers=_headers(raw))

    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()
