"""Block K — per-user chat home directories.

Each user gets their own bind-mounted HOME ({chat_home_root}/{username}) where
the claude/codex CLIs keep credentials natively — the simplest per-user
isolation (the user's suggestion). The OAuth flow writes the minted tokens into
this home in the exact shape each CLI expects; the claude subprocess then runs
with HOME set to it, and the codex access token is read back from it.

Credential shapes follow CentralStation's hard-won details:
- claude: ~/.claude/.credentials.json nested under `claudeAiOauth`, with
  `expiresAt` an int **milliseconds** since epoch forced into the future (else
  `claude --print` skips OAuth refresh and returns "Not logged in"), plus the
  scopes/subscriptionType/rateLimitTier fields the CLI requires to accept the
  credential.
- codex: ~/.codex/auth.json with the access/refresh tokens + expiry.
"""

from __future__ import annotations

import json
import os
import re
import time
from pathlib import Path
from typing import Any

# Usernames come from authenticated identities, but sanitize before using one
# as a path segment (defense-in-depth against traversal).
_SAFE = re.compile(r"[^A-Za-z0-9._-]")

_CLAUDE_DEFAULT_SCOPES = [
    "user:file_upload",
    "user:inference",
    "user:mcp_servers",
    "user:profile",
    "user:sessions:claude_code",
]


def home_for(root: str, username: str) -> Path:
    """The user's home dir, created if absent."""
    safe = _SAFE.sub("_", username) or "unknown"
    home = Path(root) / safe
    home.mkdir(parents=True, exist_ok=True)
    return home


def write_claude_credentials(home: Path, access_token: str, refresh_token: str, expires_at: float) -> None:
    """Write ~/.claude/.credentials.json in the shape `claude auth login`
    produces. expiresAt is ms since epoch, forced at least 1h into the future
    (the DB/OAuth token is authoritative; a past expiry makes --print bail)."""
    cdir = home / ".claude"
    cdir.mkdir(parents=True, exist_ok=True)
    path = cdir / ".credentials.json"
    existing: dict[str, Any] = {}
    if path.exists():
        try:
            existing = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            existing = {}
    oauth = existing.get("claudeAiOauth") or {}
    expires_ms = int(max(float(expires_at or 0), time.time() + 3600) * 1000)
    oauth.update({"accessToken": access_token, "refreshToken": refresh_token, "expiresAt": expires_ms})
    oauth.setdefault("scopes", _CLAUDE_DEFAULT_SCOPES)
    oauth.setdefault("subscriptionType", "pro")
    oauth.setdefault("rateLimitTier", "default_raven")
    existing["claudeAiOauth"] = oauth
    path.write_text(json.dumps(existing), encoding="utf-8")
    os.chmod(path, 0o600)


def write_codex_credentials(home: Path, access_token: str, refresh_token: str, expires_at: float) -> None:
    """Write ~/.codex/auth.json with the ChatGPT OAuth tokens. (Bossman's
    CodexBackend talks HTTP directly, so it just reads the access token back
    from here — no codex CLI is spawned.)"""
    cdir = home / ".codex"
    cdir.mkdir(parents=True, exist_ok=True)
    path = cdir / "auth.json"
    path.write_text(
        json.dumps({"access_token": access_token, "refresh_token": refresh_token, "expires_at": expires_at}),
        encoding="utf-8",
    )
    os.chmod(path, 0o600)


def read_codex_credentials(home: Path) -> dict[str, Any]:
    """Read back ~/.codex/auth.json ({} if absent/corrupt)."""
    path = home / ".codex" / "auth.json"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def read_claude_credentials(home: Path) -> dict[str, Any]:
    """Read the claudeAiOauth block of ~/.claude/.credentials.json ({} if absent)."""
    path = home / ".claude" / ".credentials.json"
    try:
        return (json.loads(path.read_text(encoding="utf-8")) or {}).get("claudeAiOauth") or {}
    except (OSError, ValueError):
        return {}


def auth_status(home: Path) -> dict[str, bool]:
    """Which backends this user has logged in (a credential file present)."""
    return {
        "claude_cli": bool(read_claude_credentials(home).get("accessToken")),
        "codex": bool(read_codex_credentials(home).get("access_token")),
    }
