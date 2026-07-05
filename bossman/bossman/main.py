"""Bossman — Fleet Commander for agentic-mcpd ("Duppy") node agents.

App factory pattern (create_app), not a module-level singleton: keeps the
app trivially constructible in tests without needing the real lifespan
(DB pool, poller task) to run — see tests/test_health.py.
"""

import asyncio
import contextlib
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.ext.asyncio import async_sessionmaker

from bossman.api import agents, auth, chunks, enroll, enroll_info, health, monitoring, plans, relationships, runs, translate
from bossman.config import get_settings
from bossman.db.session import make_engine
from bossman.mcp.auth import McpBearerAuthMiddleware
from bossman.mcp.server import build_mcp_server
from bossman.services import keys
from bossman.services.catalog import CatalogCache
from bossman.services.chat_client import chat_client_for
from bossman.services.embedding_client import embedding_client_for
from bossman.services.poller import poller_loop

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Engine lifetime is bound to this app instance, not the process — see
    # bossman/db/session.py's docstring for why a module-level singleton
    # broke across multiple event loops in tests (and would equally break
    # in production if the process ever hosted more than one app/loop).
    settings = get_settings()

    # Bossman's own mTLS client identity (used both to poll agents and to
    # run plans against them, see services/agent_client.client_for) should
    # exist unconditionally at startup — not only as a side effect of an
    # enrollment call, which api/enroll.py's handler also triggers this
    # from. A real bug found while first exercising bossman-ui's "run a
    # plan" flow against an agent that was inserted directly (not via
    # /api/v1/enroll): AgentClient's httpx.AsyncClient(cert=...) raised a
    # bare FileNotFoundError ("[Errno 2] No such file or directory") deep
    # inside plan_engine.run_plan's per-step try/except, which — correctly
    # per that function's own design — recorded it as a step error rather
    # than crashing, so the API still returned 200 with status: "failed"
    # and no other symptom. Best-effort, not fatal: a read-only Bossman
    # instance (or a test that never touches an agent) shouldn't refuse to
    # start just because the default /etc/bossman/tls path isn't writable
    # — the same graceful-degradation posture as every other optional
    # subsystem in this project (eBPF, PAM on the Go side).
    try:
        keys.ensure_client_keypair(settings.client_key_path, settings.client_cert_path)
    except OSError as exc:
        logger.warning(
            "could not ensure Bossman's own client keypair at %s / %s (polling and plan runs will fail "
            "until this is fixed): %s",
            settings.client_key_path,
            settings.client_cert_path,
            exc,
        )

    engine = make_engine(settings.database_url)
    app.state.session_factory = async_sessionmaker(engine, expire_on_commit=False)
    app.state.catalog_cache = CatalogCache(settings.plans_dir)
    app.state.embedding_client = embedding_client_for(settings)
    app.state.chat_client = chat_client_for(settings)

    # The MCP facade (Block B8) is mounted here rather than in create_app()
    # because it needs a real session_factory to close over, and that only
    # exists once this lifespan has started — app.mount() during startup
    # is safe since it completes before the ASGI server accepts any HTTP
    # scope, so every real request sees /mcp already registered.
    mcp_server = build_mcp_server(
        app.state.session_factory, settings, app.state.catalog_cache, app.state.embedding_client
    )
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
    # bossman-ui runs on its own origin (dev-server port, or a distinct
    # production origin) — without this, the browser's CORS preflight
    # blocks every request carrying an Authorization header or JSON body
    # before it ever reaches a route (see settings.cors_allowed_origins).
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_allowed_origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
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
    app.include_router(chunks.router, tags=["chunks"])
    app.include_router(translate.router, tags=["translate"])
    app.include_router(monitoring.router, tags=["monitoring"])
    # Always mounted (unlike POST /api/v1/enroll below) — the Settings
    # page needs a real "not configured yet" answer, not a 404.
    app.include_router(enroll_info.router, tags=["enroll"])
    # Only mounted when enrollment is actually configured — an
    # unconfigured Bossman accepts no enrollments at all, matching the Go
    # Selecta's identical gating on proxy.enroll_secret.
    if settings.enroll_secret:
        app.include_router(enroll.router, tags=["enroll"])
    return app


app = create_app()
