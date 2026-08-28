"""Block K — chat router tests: session CRUD + the SSE message endpoint.
The backend is faked by monkeypatching chat_backend_for so no real AI is
called; the DB is the docker dev DB (skipped if unreachable, via db_session).
"""

import json
import uuid

import pytest
from fastapi.testclient import TestClient

import bossman.api.chat as chat_api
from bossman.main import create_app
from bossman.services.auth import new_api_token


class FakeBackend:
    name = "claude_cli"

    def __init__(self, deltas=("Hello ", "world")):
        self._deltas = deltas

    async def stream(self, messages, **kw):
        self.seen_messages = messages
        for d in self._deltas:
            yield {"type": "delta", "text": d}


async def _make_api_token(db_session, name="chat-caller"):
    row, raw = new_api_token(name)
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


def _sse_frames(text: str) -> list:
    out = []
    for part in text.split("\n\n"):
        part = part.strip()
        if part.startswith("data:"):
            payload = part[len("data:"):].strip()
            out.append(payload)
    return out


async def test_backends_endpoint(db_session):
    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/chat/backends", headers=_headers(raw))
    assert resp.status_code == 200
    body = resp.json()
    # Asserted against the SOURCE of the list, not a copy of it. The literal set here omitted
    # `openrouter` from the day that backend was added, so this test was red while the endpoint was
    # correct — the third exact-set assertion in this suite to rot the same way. The contract worth
    # testing is "the endpoint offers exactly what chat_backend declares", and that cannot drift.
    from bossman.services.chat_backend import BACKENDS

    assert set(body["backends"]) == set(BACKENDS)
    assert body["default"] in BACKENDS
    await db_session.delete(api_token)
    await db_session.commit()


async def test_session_crud(db_session):
    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        r = client.post("/api/v1/chat/sessions", json={"label": "s1", "backend": "hermes_web"}, headers=_headers(raw))
        assert r.status_code == 200, r.text
        sid = r.json()["id"]
        assert r.json()["backend"] == "hermes_web"

        r = client.get("/api/v1/chat/sessions", headers=_headers(raw))
        assert any(s["id"] == sid for s in r.json()["sessions"])

        r = client.patch(f"/api/v1/chat/sessions/{sid}", json={"label": "renamed"}, headers=_headers(raw))
        assert r.status_code == 200 and r.json()["label"] == "renamed"

        r = client.delete(f"/api/v1/chat/sessions/{sid}", headers=_headers(raw))
        assert r.status_code == 204
        r = client.get(f"/api/v1/chat/sessions/{sid}/history", headers=_headers(raw))
        assert r.status_code == 404
    await db_session.delete(api_token)
    await db_session.commit()


async def test_create_session_bad_backend(db_session):
    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        r = client.post("/api/v1/chat/sessions", json={"backend": "bogus"}, headers=_headers(raw))
    assert r.status_code == 422
    await db_session.delete(api_token)
    await db_session.commit()


async def test_message_streams_and_persists(db_session, monkeypatch):
    api_token, raw = await _make_api_token(db_session)
    fake = FakeBackend()

    # **kwargs on purpose: the real _build_backend gained hermes_base_url / hermes_model
    # (api/chat.py), and a fake with a frozen positional signature fails with
    # "unexpected keyword argument" the moment the real one grows a parameter. Accepting
    # anything keeps the double about what it stands in for — the backend — not about the
    # call's exact shape.
    async def fake_build(settings, oauth, username, backend_name, model, **_kwargs):
        return fake

    monkeypatch.setattr(chat_api, "_build_backend", fake_build)

    with TestClient(create_app()) as client:
        sid = client.post("/api/v1/chat/sessions", json={}, headers=_headers(raw)).json()["id"]
        resp = client.post(
            f"/api/v1/chat/sessions/{sid}/message",
            json={"content": "hi there"},
            headers=_headers(raw),
        )
        assert resp.status_code == 200
        frames = _sse_frames(resp.text)
        assert frames[-1] == "[DONE]"
        deltas = [json.loads(f)["text"] for f in frames if f != "[DONE]" and json.loads(f).get("type") == "delta"]
        assert "".join(deltas) == "Hello world"

        # The user turn reached the backend, and both turns were persisted.
        assert fake.seen_messages[-1] == {"role": "user", "content": "hi there"}
        hist = client.get(f"/api/v1/chat/sessions/{sid}/history", headers=_headers(raw)).json()["messages"]
        assert [(m["role"], m["content"]) for m in hist] == [
            ("user", "hi there"),
            ("assistant", "Hello world"),
        ]

        client.delete(f"/api/v1/chat/sessions/{sid}", headers=_headers(raw))
    await db_session.delete(api_token)
    await db_session.commit()


async def test_message_empty_rejected(db_session):
    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        sid = client.post("/api/v1/chat/sessions", json={}, headers=_headers(raw)).json()["id"]
        r = client.post(f"/api/v1/chat/sessions/{sid}/message", json={"content": "  "}, headers=_headers(raw))
        assert r.status_code == 422
        client.delete(f"/api/v1/chat/sessions/{sid}", headers=_headers(raw))
    await db_session.delete(api_token)
    await db_session.commit()


async def test_session_ownership_isolated(db_session):
    owner_token, owner_raw = await _make_api_token(db_session, name="owner")
    other_token, other_raw = await _make_api_token(db_session, name="intruder")
    with TestClient(create_app()) as client:
        sid = client.post("/api/v1/chat/sessions", json={}, headers=_headers(owner_raw)).json()["id"]
        # Another identity must not see or touch it.
        assert client.get(f"/api/v1/chat/sessions/{sid}/history", headers=_headers(other_raw)).status_code == 404
        assert client.delete(f"/api/v1/chat/sessions/{sid}", headers=_headers(other_raw)).status_code == 404
        client.delete(f"/api/v1/chat/sessions/{sid}", headers=_headers(owner_raw))
    await db_session.delete(owner_token)
    await db_session.delete(other_token)
    await db_session.commit()


async def test_requires_auth(db_session):
    with TestClient(create_app()) as client:
        assert client.get("/api/v1/chat/sessions").status_code == 401
