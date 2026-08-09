"""Block K — OAuth flows for the Codex and Claude chat backends, ported from
CentralStation's per-user flow (oauth_providers.py) and adapted to Bossman.

- Codex: OAuth 2.0 Device Authorization Grant + PKCE against auth.openai.com.
  start() -> the user_code + verification URL; poll() until the user authorizes,
  then exchange the returned authorization_code (PKCE) for tokens.
- Claude: OAuth 2.0 Authorization Code + PKCE (the `claude setup-token` flow).
  start() -> an authorize URL the user opens; they copy back a "<code>#<state>"
  string; complete() exchanges it for tokens. (No device-code for Claude.)

In-memory pending-login sessions keyed by a uuid (carry the owner username) —
single-process, matching CentralStation. The httpx transport is injectable so
tests never hit the network. Token refresh helpers are here too; persistence is
in chat_credentials.py.
"""

from __future__ import annotations

import base64
import hashlib
import secrets
import time
import urllib.parse
import uuid
from typing import Any

import httpx

# --- Codex (ChatGPT) device-code + PKCE ---
CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
CODEX_ISSUER = "https://auth.openai.com"
CODEX_TOKEN_URL = f"{CODEX_ISSUER}/oauth/token"
CODEX_DEVICE_URL = f"{CODEX_ISSUER}/codex/device"  # the URL the user visits
CODEX_USERCODE_EP = f"{CODEX_ISSUER}/api/accounts/deviceauth/usercode"
CODEX_POLL_EP = f"{CODEX_ISSUER}/api/accounts/deviceauth/token"
CODEX_REDIRECT_URI = f"{CODEX_ISSUER}/deviceauth/callback"
CODEX_TIMEOUT_MIN = 15

# --- Claude authorization-code + PKCE (setup-token) ---
CLAUDE_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
CLAUDE_AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
CLAUDE_TOKEN_URL = "https://console.anthropic.com/v1/oauth/token"
CLAUDE_REDIRECT_URI = "https://console.anthropic.com/oauth/code/callback"
CLAUDE_SCOPES = "org:create_api_key user:profile user:inference"
CLAUDE_TIMEOUT_MIN = 15

REFRESH_SKEW_SECONDS = 120  # refresh a token this long before its expiry


class ChatOAuthError(Exception):
    """A recoverable OAuth failure surfaced to the caller as a 4xx/pending."""


def _pkce_pair() -> tuple[str, str]:
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode("ascii")
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode("ascii")
    return verifier, challenge


def jwt_exp(token: str) -> int:
    """The `exp` (epoch seconds) of a JWT access token, or 0 if not a JWT."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        import json

        return int(json.loads(base64.urlsafe_b64decode(payload)).get("exp") or 0)
    except Exception:  # noqa: BLE001 — a non-JWT token simply has no exp
        return 0


def token_needs_refresh(expires_at: float) -> bool:
    return bool(expires_at) and time.time() + REFRESH_SKEW_SECONDS >= float(expires_at)


class ChatOAuthService:
    def __init__(self, transport: httpx.AsyncBaseTransport | None = None, timeout: float = 30.0):
        self._transport = transport
        self._timeout = timeout
        self._codex: dict[str, dict[str, Any]] = {}
        self._claude: dict[str, dict[str, Any]] = {}

    def _client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(timeout=self._timeout, transport=self._transport)

    # ---- Codex ----------------------------------------------------------

    async def codex_start(self, username: str) -> dict[str, Any]:
        async with self._client() as client:
            resp = await client.post(CODEX_USERCODE_EP, json={"client_id": CODEX_CLIENT_ID})
        if resp.status_code != 200:
            raise ChatOAuthError(f"codex usercode failed: {resp.status_code}: {resp.text[:500]}")
        data = resp.json()
        user_code = data.get("user_code")
        device_auth_id = data.get("device_auth_id")
        interval = int(data.get("interval") or 5)
        if not user_code or not device_auth_id:
            raise ChatOAuthError("codex usercode response missing user_code/device_auth_id")
        sid = uuid.uuid4().hex
        self._codex[sid] = {
            "username": username,
            "device_auth_id": device_auth_id,
            "user_code": user_code,
            "created": time.time(),
        }
        return {
            "session_id": sid,
            "user_code": user_code,
            "verification_uri": CODEX_DEVICE_URL,
            "poll_interval_seconds": interval,
            "expires_in_minutes": CODEX_TIMEOUT_MIN,
        }

    async def codex_poll(self, session_id: str, username: str) -> dict[str, Any]:
        sess = self._codex.get(session_id)
        if sess is None or sess["username"] != username:
            raise ChatOAuthError("unknown codex login session")
        if time.time() - sess["created"] > CODEX_TIMEOUT_MIN * 60:
            self._codex.pop(session_id, None)
            return {"status": "timeout"}
        async with self._client() as client:
            resp = await client.post(
                CODEX_POLL_EP, json={"device_auth_id": sess["device_auth_id"], "user_code": sess["user_code"]}
            )
            if resp.status_code in (403, 404):
                return {"status": "pending"}
            if resp.status_code != 200:
                raise ChatOAuthError(f"codex poll failed: {resp.status_code}: {resp.text[:500]}")
            data = resp.json()
            code = data.get("authorization_code")
            verifier = data.get("code_verifier")
            if not code or not verifier:
                return {"status": "pending"}
            # Exchange the authorization code (PKCE) for tokens.
            tok = await client.post(
                CODEX_TOKEN_URL,
                data={
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": CODEX_REDIRECT_URI,
                    "client_id": CODEX_CLIENT_ID,
                    "code_verifier": verifier,
                },
            )
        if tok.status_code != 200:
            raise ChatOAuthError(f"codex token exchange failed: {tok.status_code}: {tok.text[:500]}")
        t = tok.json()
        self._codex.pop(session_id, None)
        access = t.get("access_token", "")
        return {
            "status": "authorized",
            "access_token": access,
            "refresh_token": t.get("refresh_token", ""),
            "expires_at": jwt_exp(access),
        }

    async def codex_refresh(self, refresh_token: str) -> dict[str, Any]:
        async with self._client() as client:
            resp = await client.post(
                CODEX_TOKEN_URL,
                data={"grant_type": "refresh_token", "refresh_token": refresh_token, "client_id": CODEX_CLIENT_ID},
            )
        if resp.status_code != 200:
            raise ChatOAuthError(f"codex refresh failed: {resp.status_code}: {resp.text[:500]}")
        t = resp.json()
        access = t.get("access_token", "")
        return {
            "access_token": access,
            "refresh_token": t.get("refresh_token") or refresh_token,  # some flows don't rotate
            "expires_at": jwt_exp(access),
        }

    # ---- Claude ---------------------------------------------------------

    async def claude_start(self, username: str) -> dict[str, Any]:
        verifier, challenge = _pkce_pair()
        state = secrets.token_urlsafe(24)
        params = {
            "code": "true",  # claude.ai then shows the code for manual copy
            "client_id": CLAUDE_CLIENT_ID,
            "response_type": "code",
            "redirect_uri": CLAUDE_REDIRECT_URI,
            "scope": CLAUDE_SCOPES,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": state,
        }
        sid = uuid.uuid4().hex
        self._claude[sid] = {"username": username, "state": state, "verifier": verifier, "created": time.time()}
        return {
            "session_id": sid,
            "authorize_url": f"{CLAUDE_AUTHORIZE_URL}?{urllib.parse.urlencode(params)}",
            "expires_in_minutes": CLAUDE_TIMEOUT_MIN,
        }

    async def claude_complete(self, session_id: str, username: str, code: str) -> dict[str, Any]:
        sess = self._claude.get(session_id)
        if sess is None or sess["username"] != username:
            raise ChatOAuthError("unknown claude login session")
        # claude.ai returns "<code>#<state>" — split it (CentralStation quirk).
        raw = (code or "").strip()
        code_part, state_part = raw, sess["state"]
        if "#" in raw:
            code_part, state_part = raw.split("#", 1)
        async with self._client() as client:
            resp = await client.post(
                CLAUDE_TOKEN_URL,
                json={
                    "grant_type": "authorization_code",
                    "code": code_part,
                    "state": state_part,
                    "client_id": CLAUDE_CLIENT_ID,
                    "redirect_uri": CLAUDE_REDIRECT_URI,
                    "code_verifier": sess["verifier"],
                },
            )
        if resp.status_code != 200:
            raise ChatOAuthError(f"claude token exchange failed: {resp.status_code}: {resp.text[:500]}")
        t = resp.json()
        self._claude.pop(session_id, None)
        expires_in = int(t.get("expires_in") or 0)
        return {
            "status": "authorized",
            "access_token": t.get("access_token", ""),
            "refresh_token": t.get("refresh_token", ""),
            "expires_at": (time.time() + expires_in) if expires_in else 0,
        }

    async def claude_refresh(self, refresh_token: str) -> dict[str, Any]:
        async with self._client() as client:
            resp = await client.post(
                CLAUDE_TOKEN_URL,
                json={"grant_type": "refresh_token", "refresh_token": refresh_token, "client_id": CLAUDE_CLIENT_ID},
            )
        if resp.status_code != 200:
            raise ChatOAuthError(f"claude refresh failed: {resp.status_code}: {resp.text[:500]}")
        t = resp.json()
        expires_in = int(t.get("expires_in") or 0)
        return {
            "access_token": t.get("access_token", ""),
            "refresh_token": t.get("refresh_token") or refresh_token,
            "expires_at": (time.time() + expires_in) if expires_in else 0,
        }
