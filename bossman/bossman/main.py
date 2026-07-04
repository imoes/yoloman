"""Bossman — Fleet Commander for agentic-mcpd ("Duppy") node agents.

App factory pattern (create_app), not a module-level singleton: keeps the
app trivially constructible in tests without needing the real lifespan
(DB pool, poller task) to run — see tests/test_health.py.
"""

import asyncio
import contextlib
from contextlib import asynccontextmanager

from fastapi import FastAPI
from sqlalchemy.ext.asyncio import async_sessionmaker

from bossman.api import agents, auth, enroll, health, plans, relationships, runs
from bossman.config import get_settings
from bossman.db.session import make_engine
from bossman.mcp.auth import McpBearerAuthMiddleware
from bossman.mcp.server import build_mcp_server
from bossman.services.catalog import CatalogCache
from bossman.services.poller import poller_loop


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Engine lifetime is bound to this app instance, not the process — see
    # bossman/db/session.py's docstring for why a module-level singleton
    # broke across multiple event loops in tests (and would equally break
    # in production if the process ever hosted more than one app/loop).
    settings = get_settings()
    engine = make_engine(settings.database_url)
    app.state.session_factory = async_sessionmaker(engine, expire_on_commit=False)
    app.state.catalog_cache = CatalogCache(settings.plans_dir)

    # The MCP facade (Block B8) is mounted here rather than in create_app()
    # because it needs a real session_factory to close over, and that only
    # exists once this lifespan has started — app.mount() during startup
    # is safe since it completes before the ASGI server accepts any HTTP
    # scope, so every real request sees /mcp already registered.
    mcp_server = build_mcp_server(app.state.session_factory, settings, app.state.catalog_cache)
    mcp_app = mcp_server.streamable_http_app()  # must run before .session_manager is accessed below
    app.mount("/mcp", McpBearerAuthMiddleware(mcp_app, app.state.session_factory))

    stop_event = asyncio.Event()
    poller_task = asyncio.create_task(poller_loop(app.state.session_factory, settings, stop_event))
    try:
        async with mcp_server.session_manager.run():
            yield
    finally:
        # Cancel rather than just signal-and-wait: an in-flight poll
        # cycle can be blocked on a slow/unreachable agent's HTTP request
        # (up to its own 30s timeout) — cancellation interrupts that
        # immediately instead of stalling shutdown (and every test that
        # exercises the lifespan) for up to 30 seconds.
        stop_event.set()
        poller_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await poller_task
        await engine.dispose()


def create_app() -> FastAPI:
    settings = get_settings()  # fail fast on invalid configuration
    app = FastAPI(title="Bossman", lifespan=lifespan)
    # Bare /healthz, no /api/v1 prefix — matches the Go node agent's own
    # convention (an unauthenticated liveness check needs no API versioning).
    app.include_router(health.router, tags=["health"])
    # Always mounted, unlike enroll below — login should always be
    # attemptable (a wrong/nonexistent user gets a normal 401), there's no
    # equivalent "not configured" state for human auth the way enrollment
    # has proxy.enroll_secret.
    app.include_router(auth.router, tags=["auth"])
    # The fleet inventory/plan/run REST surface (Block B7) — every route
    # in these routers is individually gated behind get_current_identity,
    # so there's no conditional mounting here the way enroll needs.
    app.include_router(agents.router, tags=["agents"])
    app.include_router(relationships.router, tags=["relationships"])
    app.include_router(plans.router, tags=["plans"])
    app.include_router(runs.router, tags=["runs"])
    # Only mounted when enrollment is actually configured — an
    # unconfigured Bossman accepts no enrollments at all, matching the Go
    # Selecta's identical gating on proxy.enroll_secret.
    if settings.enroll_secret:
        app.include_router(enroll.router, tags=["enroll"])
    return app


app = create_app()
