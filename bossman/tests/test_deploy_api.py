"""End-to-end tests for POST /api/v1/enroll/deploy (Block N-enroll). The
route is always mounted; when deploy isn't configured it must return a
helpful 400, not a 404. The happy path (real SSH) is verified live.
"""

from fastapi.testclient import TestClient

from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _make_api_token(db_session):
    row, raw = new_api_token("deploy-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


async def test_deploy_requires_auth():
    with TestClient(create_app()) as client:
        resp = client.post("/api/v1/enroll/deploy", json={"host": "h.example.com"})
    assert resp.status_code == 401


async def test_deploy_400_when_not_configured(db_session, monkeypatch):
    monkeypatch.delenv("BOSSMAN_DEPLOY_SSH_USER", raising=False)
    monkeypatch.delenv("BOSSMAN_AGENT_DEB_PATH", raising=False)
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/enroll/deploy",
            json={"host": "h.example.com"},
            headers={"Authorization": f"Bearer {raw}"},
        )

    assert resp.status_code == 400
    assert "not configured" in resp.json()["detail"]

    await db_session.delete(api_token)
    await db_session.commit()
