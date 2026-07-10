"""Block K — OAuth flow + per-user home-dir credential tests. httpx is mocked;
no network, no real provider. Covers the Codex device-code and Claude
authorization-code (setup-token) flows and the home-dir credential shapes.
"""

import json

import httpx
import pytest

from bossman.services import chat_home
from bossman.services.chat_oauth import (
    CLAUDE_TOKEN_URL,
    CODEX_POLL_EP,
    CODEX_TOKEN_URL,
    CODEX_USERCODE_EP,
    ChatOAuthError,
    ChatOAuthService,
)


async def test_codex_device_flow_start_poll_exchange():
    state = {"polls": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if url == CODEX_USERCODE_EP:
            return httpx.Response(200, json={"user_code": "WXYZ-1234", "device_auth_id": "dev-1", "interval": 5})
        if url == CODEX_POLL_EP:
            state["polls"] += 1
            if state["polls"] == 1:
                return httpx.Response(403, json={})  # still pending
            return httpx.Response(200, json={"authorization_code": "authcode", "code_verifier": "verif"})
        if url == CODEX_TOKEN_URL:
            body = dict(httpx.QueryParams(request.content.decode()))
            assert body["grant_type"] == "authorization_code" and body["code"] == "authcode"
            return httpx.Response(200, json={"access_token": "codex-access", "refresh_token": "codex-refresh"})
        return httpx.Response(404)

    svc = ChatOAuthService(transport=httpx.MockTransport(handler))
    start = await svc.codex_start("alice")
    assert start["user_code"] == "WXYZ-1234" and "verification_uri" in start
    sid = start["session_id"]

    assert (await svc.codex_poll(sid, "alice"))["status"] == "pending"
    done = await svc.codex_poll(sid, "alice")
    assert done["status"] == "authorized" and done["access_token"] == "codex-access"


async def test_codex_poll_rejects_other_user():
    def handler(request):
        return httpx.Response(200, json={"user_code": "A", "device_auth_id": "d", "interval": 5})

    svc = ChatOAuthService(transport=httpx.MockTransport(handler))
    sid = (await svc.codex_start("alice"))["session_id"]
    with pytest.raises(ChatOAuthError):
        await svc.codex_poll(sid, "mallory")


async def test_claude_authcode_flow():
    def handler(request: httpx.Request) -> httpx.Response:
        if str(request.url) == CLAUDE_TOKEN_URL:
            payload = json.loads(request.content)
            assert payload["grant_type"] == "authorization_code"
            assert payload["code"] == "thecode" and payload["state"] == "thestate"  # split on '#'
            return httpx.Response(200, json={"access_token": "cl-access", "refresh_token": "cl-refresh", "expires_in": 3600})
        return httpx.Response(404)

    svc = ChatOAuthService(transport=httpx.MockTransport(handler))
    start = await svc.claude_start("alice")
    assert "claude.ai/oauth/authorize" in start["authorize_url"]
    sid = start["session_id"]
    result = await svc.claude_complete(sid, "alice", "thecode#thestate")
    assert result["status"] == "authorized" and result["access_token"] == "cl-access"
    assert result["expires_at"] > 0


async def test_claude_refresh():
    def handler(request):
        return httpx.Response(200, json={"access_token": "new", "expires_in": 3600})

    svc = ChatOAuthService(transport=httpx.MockTransport(handler))
    r = await svc.claude_refresh("old-refresh")
    assert r["access_token"] == "new" and r["refresh_token"] == "old-refresh"  # kept when not rotated


# ---- per-user home dir credential storage ----------------------------------


def test_home_dirs_are_per_user(tmp_path):
    a = chat_home.home_for(str(tmp_path), "alice")
    b = chat_home.home_for(str(tmp_path), "bob")
    assert a != b and a.exists() and b.exists()
    # traversal-ish username is sanitized to a single safe segment
    weird = chat_home.home_for(str(tmp_path), "../../etc")
    assert weird.parent == tmp_path


def test_claude_credentials_shape(tmp_path):
    home = chat_home.home_for(str(tmp_path), "alice")
    chat_home.write_claude_credentials(home, "acc", "ref", 0)  # 0 -> forced future
    raw = json.loads((home / ".claude" / ".credentials.json").read_text())
    oauth = raw["claudeAiOauth"]
    assert oauth["accessToken"] == "acc" and oauth["refreshToken"] == "ref"
    assert oauth["expiresAt"] > 1_000_000_000_000  # ms, in the future
    assert "scopes" in oauth and oauth["subscriptionType"] == "pro"
    assert chat_home.auth_status(home)["claude_cli"] is True


def test_codex_credentials_roundtrip(tmp_path):
    home = chat_home.home_for(str(tmp_path), "alice")
    assert chat_home.auth_status(home)["codex"] is False
    chat_home.write_codex_credentials(home, "acc", "ref", 123.0)
    assert chat_home.read_codex_credentials(home)["access_token"] == "acc"
    assert chat_home.auth_status(home)["codex"] is True
