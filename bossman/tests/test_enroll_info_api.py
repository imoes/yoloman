"""End-to-end tests for GET /api/v1/enroll/info through the real FastAPI
app and real database (see tests/conftest.py's db_session fixture).
Enrollment is open (no secret), so info always reports configured=True with
a secret-free register command; deploy_configured is independent.
"""

from fastapi.testclient import TestClient

from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _make_api_token(db_session):
    row, raw = new_api_token("enroll-info-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def test_enroll_info_requires_auth():
    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/enroll/info")
    assert resp.status_code == 401


async def test_enroll_info_reports_deploy_configured(db_session, monkeypatch):
    """Block N-enroll: deploy_configured flips true once an SSH user AND an
    agent .deb path are set, independently of enrollment (which is always
    open now)."""
    monkeypatch.setenv("BOSSMAN_DEPLOY_SSH_USER", "marvin")
    monkeypatch.setenv("BOSSMAN_AGENT_DEB_PATH", "/opt/agentic-mcp.deb")
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/enroll/info", headers=_headers(raw))

    body = resp.json()
    assert body["configured"] is True  # enrollment is always open
    assert body["deploy_configured"] is True

    await db_session.delete(api_token)
    await db_session.commit()


async def test_enroll_info_reports_secret_free_command(db_session, monkeypatch):
    monkeypatch.setenv("BOSSMAN_PUBLIC_URL", "https://bossman.example.com:8000")
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/enroll/info", headers=_headers(raw))

    assert resp.status_code == 200
    body = resp.json()
    assert body["configured"] is True
    assert body["enroll_url"] == "https://bossman.example.com:8000"
    assert "enroll_secret" not in body
    assert body["register_command"] == (
        "agentic-mcpd register --enroll-url https://bossman.example.com:8000 --name $(hostname)"
    )
    assert "--enroll-secret" not in body["register_command"]

    await db_session.delete(api_token)
    await db_session.commit()


async def test_enroll_info_falls_back_to_placeholder_url_when_public_url_unset(db_session, monkeypatch):
    monkeypatch.delenv("BOSSMAN_PUBLIC_URL", raising=False)
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/enroll/info", headers=_headers(raw))

    body = resp.json()
    assert body["configured"] is True
    assert "<this-bossman-host>" in body["enroll_url"]

    await db_session.delete(api_token)
    await db_session.commit()
