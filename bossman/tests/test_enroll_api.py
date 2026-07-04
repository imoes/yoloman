"""End-to-end tests for POST /api/v1/enroll through the real FastAPI app
and the real database (see tests/conftest.py's db_session fixture) — not
a mocked session. Cleans up any agent rows it creates via db_session's own
delete+commit, since the route commits through its own, separate session.

Every TestClient use here is a `with TestClient(app) as client:` context
manager — that's what actually triggers the app's lifespan (startup sets
app.state.session_factory; see bossman/main.py), which the /api/v1/enroll
route depends on via bossman.db.session.get_session.
"""

import uuid

from fastapi.testclient import TestClient
from sqlalchemy import select

from bossman.db.models import Agent
from bossman.main import create_app


def _make_app(tmp_path, monkeypatch, enroll_secret="test-enroll-secret"):
    monkeypatch.setenv("BOSSMAN_ENROLL_SECRET", enroll_secret)
    monkeypatch.setenv("BOSSMAN_CLIENT_KEY_PATH", str(tmp_path / "bossman-client.key"))
    monkeypatch.setenv("BOSSMAN_CLIENT_CERT_PATH", str(tmp_path / "bossman-client.crt"))
    return create_app()


async def test_enroll_creates_agent_and_returns_public_key(tmp_path, monkeypatch, db_session):
    app = _make_app(tmp_path, monkeypatch)
    name = f"api-enroll-{uuid.uuid4().hex[:8]}"

    with TestClient(app) as client:
        resp = client.post(
            "/api/v1/enroll",
            json={"name": name, "enroll_secret": "test-enroll-secret", "token": "tok", "address": "1.2.3.4:8010"},
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["agent_id"]
    assert body["bossman_public_key"].startswith("-----BEGIN PUBLIC KEY-----")

    got = await db_session.scalar(select(Agent).where(Agent.name == name))
    assert got is not None
    assert got.enrollment_state == "enrolled"
    assert got.token == "tok"
    assert got.address == "1.2.3.4:8010"

    await db_session.delete(got)
    await db_session.commit()


async def test_enroll_reuses_the_same_keypair_across_calls(tmp_path, monkeypatch, db_session):
    app = _make_app(tmp_path, monkeypatch)
    name1 = f"api-enroll-{uuid.uuid4().hex[:8]}"
    name2 = f"api-enroll-{uuid.uuid4().hex[:8]}"

    with TestClient(app) as client:
        resp1 = client.post(
            "/api/v1/enroll", json={"name": name1, "enroll_secret": "test-enroll-secret", "token": "t1"}
        )
        resp2 = client.post(
            "/api/v1/enroll", json={"name": name2, "enroll_secret": "test-enroll-secret", "token": "t2"}
        )

    assert resp1.json()["bossman_public_key"] == resp2.json()["bossman_public_key"]

    for name in (name1, name2):
        got = await db_session.scalar(select(Agent).where(Agent.name == name))
        if got is not None:
            await db_session.delete(got)
    await db_session.commit()


def test_enroll_wrong_secret_rejected(tmp_path, monkeypatch):
    app = _make_app(tmp_path, monkeypatch)

    with TestClient(app) as client:
        resp = client.post(
            "/api/v1/enroll",
            json={"name": "whoever", "enroll_secret": "wrong", "token": "tok"},
        )

    assert resp.status_code == 401


def test_enroll_route_absent_when_no_secret_configured(monkeypatch):
    monkeypatch.delenv("BOSSMAN_ENROLL_SECRET", raising=False)

    with TestClient(create_app()) as client:
        resp = client.post("/api/v1/enroll", json={"name": "x", "enroll_secret": "", "token": "t"})

    assert resp.status_code == 404
