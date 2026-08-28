"""End-to-end tests for POST /api/v1/auth/login and the get_current_identity
dependency through the real FastAPI app and real database (see
tests/conftest.py's db_session fixture) — not mocked. Every TestClient use
is a `with TestClient(app) as client:` context manager so the lifespan
actually runs (see bossman/main.py, bossman/db/session.py).
"""

import uuid
from tests.naming import owned_name

from fastapi import Depends
from fastapi.testclient import TestClient
from sqlalchemy import select

from bossman.api.auth import get_current_identity, router as auth_router
from bossman.db.models import BossmanUser
from bossman.main import create_app
from bossman.services.auth import new_api_token, new_bossman_user


def _make_app(monkeypatch, jwt_secret="test-secret-at-least-32-bytes-long"):
    monkeypatch.setenv("BOSSMAN_JWT_SECRET", jwt_secret)
    return create_app()


async def test_login_success_returns_jwt(monkeypatch, db_session):
    app = _make_app(monkeypatch)
    user = new_bossman_user(owned_name("alice"), "s3cret!", role="admin")
    db_session.add(user)
    await db_session.flush()
    await db_session.commit()

    with TestClient(app) as client:
        resp = client.post("/api/v1/auth/login", json={"username": user.username, "password": "s3cret!"})

    assert resp.status_code == 200
    body = resp.json()
    assert body["token_type"] == "bearer"
    assert body["access_token"]

    got = await db_session.scalar(select(BossmanUser).where(BossmanUser.username == user.username))
    await db_session.delete(got)
    await db_session.commit()


def test_login_wrong_password_rejected(monkeypatch):
    app = _make_app(monkeypatch)

    with TestClient(app) as client:
        resp = client.post("/api/v1/auth/login", json={"username": "nobody", "password": "wrong"})

    assert resp.status_code == 401


def _protected_test_app(monkeypatch, jwt_secret="test-secret-at-least-32-bytes-long"):
    """A minimal FastAPI app with one route gated behind
    get_current_identity — used to test the dependency itself end to end,
    since bossman.main doesn't yet mount any protected route (that's
    Block B7's job)."""
    monkeypatch.setenv("BOSSMAN_JWT_SECRET", jwt_secret)
    app = create_app()
    app.include_router(auth_router)

    @app.get("/api/v1/whoami")
    async def whoami(identity=Depends(get_current_identity)):
        return {"kind": identity.kind, "name": identity.name}

    return app


async def test_protected_route_accepts_jwt_from_login(monkeypatch, db_session):
    app = _protected_test_app(monkeypatch)
    user = new_bossman_user(owned_name("carol"), "s3cret!", role="operator")
    db_session.add(user)
    await db_session.flush()
    await db_session.commit()

    with TestClient(app) as client:
        login_resp = client.post("/api/v1/auth/login", json={"username": user.username, "password": "s3cret!"})
        token = login_resp.json()["access_token"]
        resp = client.get("/api/v1/whoami", headers={"Authorization": f"Bearer {token}"})

    assert resp.status_code == 200
    assert resp.json() == {"kind": "user", "name": user.username}

    got = await db_session.scalar(select(BossmanUser).where(BossmanUser.username == user.username))
    await db_session.delete(got)
    await db_session.commit()


async def test_protected_route_accepts_api_token(monkeypatch, db_session):
    app = _protected_test_app(monkeypatch)
    row, raw = new_api_token("mcp-facade")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()

    with TestClient(app) as client:
        resp = client.get("/api/v1/whoami", headers={"Authorization": f"Bearer {raw}"})

    assert resp.status_code == 200
    assert resp.json() == {"kind": "api_token", "name": "mcp-facade"}

    await db_session.delete(row)
    await db_session.commit()


def test_protected_route_rejects_missing_header(monkeypatch):
    app = _protected_test_app(monkeypatch)

    with TestClient(app) as client:
        resp = client.get("/api/v1/whoami")

    assert resp.status_code == 401


def test_protected_route_rejects_garbage_bearer(monkeypatch):
    app = _protected_test_app(monkeypatch)

    with TestClient(app) as client:
        resp = client.get("/api/v1/whoami", headers={"Authorization": "Bearer complete-garbage"})

    assert resp.status_code == 401
