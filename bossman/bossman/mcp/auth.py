"""Bearer-token gate for the mounted MCP facade (see docs/plan.md's
Bossman plan, section B.6/B.8): the MCP facade is exclusively for
machine/AI callers, never a human dashboard login, so only a valid
Bossman api_token is accepted here — never a JWT. Implemented as raw ASGI
middleware rather than the mcp SDK's own OAuth-flavored TokenVerifier/
AuthSettings machinery: that machinery targets full OAuth2 resource-server
flows (issuer URLs, scopes, a registered authorization server), far more
than a single shared-secret bearer token needs, and it would mean
re-implementing services.auth's already-correct api_tokens verification a
second time inside an OAuth adapter instead of calling it directly.
"""

from __future__ import annotations

import contextvars
import json

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.services.auth import AuthError, Identity, authenticate_api_token

# Set by the middleware for the duration of one request, read by MCP tools
# (see bossman/mcp/server.py's run_plan) that want to record which caller
# actually triggered an action — task-local, so it does not leak between
# concurrent requests.
current_identity: contextvars.ContextVar[str | None] = contextvars.ContextVar("bossman_mcp_identity", default=None)
# The same caller as a services.auth.Identity (kind api_token, with the token's UID), for tools that
# authorise against the host ACL exactly as the REST routes do (user_can_manage_agent).
current_auth_identity: contextvars.ContextVar[Identity | None] = contextvars.ContextVar(
    "bossman_mcp_auth_identity", default=None)


class McpBearerAuthMiddleware:
    def __init__(self, app, session_factory: async_sessionmaker[AsyncSession]):
        self.app = app
        self.session_factory = session_factory

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        headers = dict(scope.get("headers") or [])
        auth_header = headers.get(b"authorization", b"").decode()
        if not auth_header.lower().startswith("bearer "):
            await _send_401(send, "missing bearer token")
            return
        token = auth_header[len("bearer ") :]

        async with self.session_factory() as session:
            try:
                api_token = await authenticate_api_token(session, token)
            except AuthError:
                await _send_401(send, "invalid or revoked API token")
                return

        reset_token = current_identity.set(api_token.name)
        reset_auth = current_auth_identity.set(Identity(kind="api_token", name=api_token.name, token_id=api_token.id))
        try:
            await self.app(scope, receive, send)
        finally:
            current_auth_identity.reset(reset_auth)
            current_identity.reset(reset_token)


async def _send_401(send, detail: str) -> None:
    body = json.dumps({"detail": detail}).encode()
    await send(
        {
            "type": "http.response.start",
            "status": 401,
            "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())],
        }
    )
    await send({"type": "http.response.body", "body": body})
