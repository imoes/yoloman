"""End-to-end tests for the MCP facade's bearer-auth gate (see
bossman/mcp/auth.py) and, in test_mcp_route_full_session_with_valid_api_token,
a genuine real MCP client session — not the tool closures directly (that's
tests/test_mcp_server.py) and not just an HTTP status code (that's the
other tests here) — driven in-process against the actual mounted app.

This full-session test exists because a real bug (FastMCP's own internal
route also defaults to "/mcp", which doubled up to "/mcp/mcp" and 404'd
every real request once mounted at "/mcp" in bossman/main.py) was only
caught by running an actual separate-process MCP client against a real
server — no status-code-only test here would have noticed, since the
auth middleware itself was working correctly and returning a real (non-
401) response either way. This test reproduces that same protocol-level
check in-process so a regression doesn't require another manual run.
"""

import asyncio
from contextlib import asynccontextmanager

import httpx
from fastapi.testclient import TestClient
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

from bossman.main import create_app
from bossman.services.auth import new_api_token


async def test_mcp_route_rejects_missing_bearer():
    app = create_app()
    with TestClient(app) as client:
        resp = client.post("/mcp", json={"jsonrpc": "2.0", "method": "initialize", "id": 1})
    assert resp.status_code == 401
    assert resp.json()["detail"] == "missing bearer token"


async def test_mcp_route_rejects_garbage_bearer():
    app = create_app()
    with TestClient(app) as client:
        resp = client.post(
            "/mcp",
            json={"jsonrpc": "2.0", "method": "initialize", "id": 1},
            headers={"Authorization": "Bearer complete-garbage"},
        )
    assert resp.status_code == 401
    assert "invalid" in resp.json()["detail"]


@asynccontextmanager
async def _running_app(app):
    """Manually drives the ASGI lifespan protocol so an httpx.ASGITransport
    request reaches an app whose lifespan (DB engine, MCP session manager,
    poller task) has actually started. TestClient's own portal-based
    lifespan driving isn't used here because this test body already runs
    inside its own event loop (pytest-asyncio) and needs a real MCP client
    session concurrently — the two don't mix safely."""
    receive_queue: asyncio.Queue = asyncio.Queue()
    send_queue: asyncio.Queue = asyncio.Queue()
    await receive_queue.put({"type": "lifespan.startup"})

    async def receive():
        return await receive_queue.get()

    async def send(message):
        await send_queue.put(message)

    task = asyncio.create_task(app({"type": "lifespan"}, receive, send))
    startup_result = await send_queue.get()
    assert startup_result["type"] == "lifespan.startup.complete", startup_result

    try:
        yield
    finally:
        await receive_queue.put({"type": "lifespan.shutdown"})
        shutdown_result = await send_queue.get()
        assert shutdown_result["type"] == "lifespan.shutdown.complete", shutdown_result
        await task


async def test_mcp_route_full_session_with_valid_api_token(db_session):
    row, raw = new_api_token("mcp-full-session-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()

    app = create_app()

    def http_client_factory(headers=None, timeout=None, auth=None):
        return httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://127.0.0.1:8000",
            headers=headers,
            timeout=timeout or httpx.Timeout(30),
            follow_redirects=True,
        )

    async with _running_app(app):
        # "127.0.0.1:8000", not the ASGITransport default "testserver" —
        # the MCP transport's own DNS-rebinding protection
        # (transport_security) only allows the Host header FastMCP itself
        # was configured with (default host/port, since build_mcp_server
        # doesn't override them), and "testserver"/"localhost" aren't it.
        async with streamablehttp_client(
            "http://127.0.0.1:8000/mcp",
            headers={"Authorization": f"Bearer {raw}"},
            httpx_client_factory=http_client_factory,
        ) as (read, write, _):
            async with ClientSession(read, write) as session:
                init_result = await session.initialize()
                assert init_result.serverInfo.name == "bossman"

                tools = await session.list_tools()
                assert "run_plan" in [t.name for t in tools.tools]

    await db_session.delete(row)
    await db_session.commit()
