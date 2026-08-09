"""End-to-end tests for /api/v1/severity-labels (Block K10) — real app +
real DB (see tests/conftest.py's db_session fixture).
"""

from fastapi.testclient import TestClient

from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _make_api_token(db_session):
    row, raw = new_api_token("sev-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def test_severity_labels_requires_auth(db_session):
    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/severity-labels")
    assert resp.status_code == 401


async def test_list_severity_labels_returns_seeded_defaults(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/severity-labels", headers=_headers(raw))

    assert resp.status_code == 200
    by_state = {row["state"]: row for row in resp.json()}
    assert set(by_state) == {"OK", "WARN", "CRIT", "UNKNOWN"}
    assert by_state["CRIT"]["label"] == "CRIT"

    await db_session.delete(api_token)
    await db_session.commit()


async def test_update_severity_label_renames_and_recolors(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.put(
            "/api/v1/severity-labels/WARN",
            json={"label": "Degraded", "color": "#ffaa00"},
            headers=_headers(raw),
        )

    assert resp.status_code == 200
    assert resp.json() == {"state": "WARN", "label": "Degraded", "color": "#ffaa00"}

    # Restore the default so this test doesn't leak state into others in
    # the shared dev DB.
    with TestClient(create_app()) as client:
        client.put(
            "/api/v1/severity-labels/WARN", json={"label": "WARN", "color": "#ffc800"}, headers=_headers(raw)
        )

    await db_session.delete(api_token)
    await db_session.commit()


async def test_update_severity_label_invalid_state_422(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.put(
            "/api/v1/severity-labels/NOPE", json={"label": "x", "color": "#000"}, headers=_headers(raw)
        )

    assert resp.status_code == 422
    await db_session.delete(api_token)
    await db_session.commit()
