"""First-run setup: create the very first operator through the API, and never a second one.

The native install used to say "run bossman-create-admin <user> <password> on the console" — a password in
shell history, and impossible for someone who has the web console open and no shell on that host.

WHY THESE TESTS ARE SPLIT. The creation path needs an EMPTY user table, and the suite's database is the one
shared test system, which has accounts. Emptying it would be a destructive fixture that breaks every other
test. So the creation path is exercised against a stub session (the handler is a plain async function), while
the property that actually matters for safety — that setup REFUSES once an account exists — is asserted
against the real database, where accounts really do exist.
"""

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from bossman.api import auth as auth_api
from bossman.config import Settings
from bossman.main import create_app


class _StubSession:
    """Enough session for the handler: a count, an add, and a commit that either works or conflicts."""

    def __init__(self, user_count=0, conflict=False):
        self._count = user_count
        self._conflict = conflict
        self.added = []
        self.committed = False

    async def scalar(self, _stmt):
        return self._count

    def add(self, obj):
        self.added.append(obj)

    async def commit(self):
        if self._conflict:
            from sqlalchemy.exc import IntegrityError
            raise IntegrityError("insert", {}, Exception("duplicate"))
        self.committed = True

    async def rollback(self):
        pass


class _Req:
    client = None


def _settings(monkeypatch):
    """Settings with a signing secret. Built directly rather than through get_settings(), which is cached per
    process — a monkeypatched env var would not reach an instance another test already created."""
    monkeypatch.setenv("BOSSMAN_JWT_SECRET", "test-secret-at-least-32-bytes-long")
    return Settings(jwt_secret="test-secret-at-least-32-bytes-long")


async def test_setup_creates_the_first_operator_and_returns_a_token(monkeypatch):
    session = _StubSession(user_count=0)
    out = await auth_api.setup(
        auth_api.SetupRequest(username="chief", password="a-long-enough-pw"),
        _Req(), session, _settings(monkeypatch))
    assert out.access_token                      # logged in, no need to type the password again
    assert session.committed
    assert session.added[0].username == "chief" and session.added[0].role == "admin"


async def test_setup_refuses_once_any_account_exists(monkeypatch):
    # THE point of the design: a one-shot, not an unprotected signup route somebody forgot to guard.
    with pytest.raises(HTTPException) as exc:
        await auth_api.setup(auth_api.SetupRequest(username="sneak", password="another-long-pw"),
                             _Req(), _StubSession(user_count=1), _settings(monkeypatch))
    assert exc.value.status_code == 409


async def test_a_race_between_two_forms_loses_safely(monkeypatch):
    # Both browsers see an empty table; the loser's INSERT conflicts and must become a 409, not a 500.
    with pytest.raises(HTTPException) as exc:
        await auth_api.setup(auth_api.SetupRequest(username="chief", password="a-long-enough-pw"),
                             _Req(), _StubSession(user_count=0, conflict=True), _settings(monkeypatch))
    assert exc.value.status_code == 409


@pytest.mark.parametrize("username,password", [("chief", "short"), ("  ", "a-long-enough-pw"), ("x", "")])
async def test_bad_input_is_refused_without_creating_anything(monkeypatch, username, password):
    session = _StubSession(user_count=0)
    with pytest.raises(HTTPException) as exc:
        await auth_api.setup(auth_api.SetupRequest(username=username, password=password),
                             _Req(), session, _settings(monkeypatch))
    assert exc.value.status_code == 422
    assert not session.added and not session.committed


async def test_against_the_real_database_setup_is_closed(monkeypatch, db_session):
    """The safety property, against the database this installation really has: accounts exist, so the route
    must report that setup is done and refuse to run."""
    app = create_app()
    monkeypatch.setenv("BOSSMAN_JWT_SECRET", "test-secret-at-least-32-bytes-long")
    with TestClient(app) as client:
        assert client.get("/api/v1/auth/setup").json() == {"needs_setup": False}
        assert client.post("/api/v1/auth/setup",
                           json={"username": "sneak", "password": "another-long-pw"}).status_code == 409
