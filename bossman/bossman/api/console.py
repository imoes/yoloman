"""Interactive web-shell proxy (Block 2). The browser can't reach an agent
directly (only Bossman holds the mTLS client identity), so Bossman relays the
console WebSocket: browser <-> Bossman <-> agent's GET /api/v1/console (a PTY
running /bin/login). The operator authenticates in the terminal via PAM.

Auth: browsers can't set an Authorization header on a WebSocket, so the bearer
token arrives as the `token` query param; it's resolved to an Identity and the
per-host manage ACL is enforced before the upstream dial. Frames are forwarded
verbatim (binary = terminal I/O, text = the resize control message)."""

from __future__ import annotations

import asyncio
import logging
import ssl
from uuid import UUID

import websockets
from fastapi import APIRouter, WebSocket

from bossman.config import get_settings
from bossman.db.models import Agent
from bossman.services.auth import AuthError, resolve_identity, user_can_manage_agent

logger = logging.getLogger(__name__)
router = APIRouter()

# Custom close codes (4000-4999 are application-defined) surfaced to the UI.
CLOSE_UNAUTHENTICATED = 4401
CLOSE_FORBIDDEN = 4403
CLOSE_NO_AGENT = 4404
CLOSE_UPSTREAM = 4502


@router.websocket("/api/v1/agents/{agent_id}/console")
async def agent_console(websocket: WebSocket, agent_id: UUID) -> None:
    # WS routes get no `request`, so open the session from app state directly
    # (rather than the HTTP get_session dependency) and do all DB work up front;
    # the relay below needs no DB.
    settings = get_settings()
    token = websocket.query_params.get("token", "")
    if not token:
        await websocket.close(code=CLOSE_UNAUTHENTICATED)
        return
    async with websocket.app.state.session_factory() as session:
        try:
            identity = await resolve_identity(session, settings, token)
        except AuthError:
            await websocket.close(code=CLOSE_UNAUTHENTICATED)
            return
        if not await user_can_manage_agent(session, identity, agent_id):
            await websocket.close(code=CLOSE_FORBIDDEN)
            return
        agent = await session.get(Agent, agent_id)
        if agent is None or not agent.address:
            await websocket.close(code=CLOSE_NO_AGENT)
            return
        address, agent_token, host, user = agent.address, agent.token, agent.name, identity.name

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_cert_chain(settings.client_cert_path, settings.client_key_path)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # same trade-off as the REST client (see agent_client)

    uri = f"wss://{address}/api/v1/console"
    headers = {"Authorization": f"Bearer {agent_token}"} if agent_token else {}

    await websocket.accept()
    logger.info("console session opened: user=%s host=%s", user, host)
    try:
        async with websockets.connect(uri, ssl=ctx, additional_headers=headers, max_size=None) as upstream:
            await _relay(websocket, upstream)
    except (OSError, websockets.WebSocketException) as exc:
        logger.warning("console upstream failed for %s: %s", host, exc)
        await websocket.close(code=CLOSE_UPSTREAM)
    finally:
        logger.info("console session closed: user=%s host=%s", user, host)


async def _relay(browser: WebSocket, upstream: websockets.ClientConnection) -> None:
    """Pump frames both ways until either side closes; type-preserving so the
    resize control (text) and terminal I/O (binary) both survive."""

    async def browser_to_upstream() -> None:
        while True:
            msg = await browser.receive()
            if msg["type"] == "websocket.disconnect":
                return
            if msg.get("bytes") is not None:
                await upstream.send(msg["bytes"])
            elif msg.get("text") is not None:
                await upstream.send(msg["text"])

    async def upstream_to_browser() -> None:
        async for msg in upstream:
            if isinstance(msg, bytes):
                await browser.send_bytes(msg)
            else:
                await browser.send_text(msg)

    tasks = [asyncio.create_task(browser_to_upstream()), asyncio.create_task(upstream_to_browser())]
    try:
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for t in pending:
            t.cancel()
        for t in done:
            exc = t.exception()
            if exc and not isinstance(exc, (websockets.WebSocketException, RuntimeError)):
                raise exc
    finally:
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
