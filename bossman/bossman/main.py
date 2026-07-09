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

from bossman.api import admin, agents, auth, chunks, dashboard, deploy, enroll, enroll_info, graphs, health, host_groups, management, modules, monitoring, notifications, orchestration, ou, plans, processes, relationships, runs, severity_labels, system_settings, templates, translate, value_maps
from bossman.config import get_settings
from bossman.db.session import make_engine
from bossman.mcp.auth import McpBearerAuthMiddleware
from bossman.mcp.server import build_mcp_server
from bossman.services import keys, plan_store
from bossman.services.catalog import CatalogCache
from bossman.services.chat_client import chat_client_for
from bossman.services.embedding_client import embedding_client_for
from bossman.services.housekeeping import HousekeepingStats, housekeeping_loop
from bossman.services.monitoring import seed_default_check_rules
from bossman.services.poller import PollerStats, poller_loop
from bossman.services.reconciler import ReconcileStats, reconciler_loop

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
    app.state.engine = engine
    app.state.session_factory = async_sessionmaker(engine, expire_on_commit=False)

    # Seed the built-in-check default rules (Block H6) so Memory/Disk show
    # up as editable, host-overridable rules and the Bossman evaluator
    # grades them instead of the agent's fixed thresholds. Idempotent;
    # skipped in the test suite (settings.seed_default_checks) so the
    # seeded global rules don't pollute shared-DB count assertions.
    if settings.seed_default_checks:
        async with app.state.session_factory() as session:
            await seed_default_check_rules(session)

    # docs/zielbestimmung.md #5: import the file-based plans_dir plans into
    # the canonical store at startup — the store is the source of truth;
    # plans_dir is now just an import source. Best-effort: a bad plan is
    # skipped inside import_plans_dir, and a DB hiccup here must not stop the
    # app from serving (the file-backed catalog below still works).
    async with app.state.session_factory() as session:
        try:
            stored, failed = await plan_store.import_plans_dir(session, settings.plans_dir)
            await session.commit()
            if stored or failed:
                logger.info("imported plans_dir into the store", extra={"stored": stored, "failed": failed})
        except Exception:  # noqa: BLE001 — never let plan import break startup
            await session.rollback()
            logger.warning("plans_dir → store import failed at startup", exc_info=True)

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

    # Block K2 (Zabbix gap-analysis, "runtime operational control plane"):
    # both background loops report their last-run outcome here so
    # GET /api/v1/admin/diagnostics has something real to show, without
    # Bossman needing a persistent queue of its own.
    app.state.poller_stats = PollerStats()
    app.state.housekeeping_stats = HousekeepingStats()
    # Block L4: the desired-state reconciler drains controller_outbox,
    # recompiles affected hosts and enqueues agent_config_delivery rows.
    app.state.reconcile_stats = ReconcileStats()

    stop_event = asyncio.Event()
    poller_task = asyncio.create_task(poller_loop(app.state.session_factory, settings, stop_event, app.state.poller_stats))
    housekeeping_task = asyncio.create_task(
        housekeeping_loop(app.state.session_factory, settings, stop_event, app.state.housekeeping_stats)
    )
    reconciler_task = asyncio.create_task(
        reconciler_loop(app.state.session_factory, settings, stop_event, app.state.reconcile_stats)
    )
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
        housekeeping_task.cancel()
        reconciler_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await poller_task
        with contextlib.suppress(asyncio.CancelledError):
            await housekeeping_task
        with contextlib.suppress(asyncio.CancelledError):
            await reconciler_task
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
    app.include_router(processes.router, tags=["processes"])
    app.include_router(management.router, tags=["management"])
    app.include_router(relationships.router, tags=["relationships"])
    app.include_router(plans.router, tags=["plans"])
    app.include_router(runs.router, tags=["runs"])
    app.include_router(chunks.router, tags=["chunks"])
    app.include_router(translate.router, tags=["translate"])
    app.include_router(monitoring.router, tags=["monitoring"])
    app.include_router(dashboard.router, tags=["dashboard"])
    app.include_router(modules.router, tags=["modules"])
    app.include_router(notifications.router, tags=["notifications"])
    app.include_router(admin.router, tags=["admin"])
    app.include_router(value_maps.router, tags=["value-maps"])
    app.include_router(severity_labels.router, tags=["severity-labels"])
    app.include_router(graphs.router, tags=["graphs"])
    app.include_router(templates.router, tags=["templates"])
    app.include_router(ou.router, tags=["ou"])
    app.include_router(host_groups.router, tags=["host-groups"])
    app.include_router(orchestration.router, tags=["orchestration"])
    app.include_router(system_settings.router, tags=["system-settings"])
    # Block L4 is PUSH, not pull: Bossman's reconciler (services/reconciler.py)
    # POSTs each new generation to the agent's own POST /api/v1/config/apply
    # over the existing mTLS channel. There is deliberately NO agent-facing
    # ingress here — the agent never dials into Bossman (single firewall rule
    # Bossman -> agent), see docs/policy-orchestration-architecture.md §6.
    # Always mounted (unlike POST /api/v1/enroll below) — the Settings
    # page needs a real "not configured yet" answer, not a 404.
    app.include_router(enroll_info.router, tags=["enroll"])
    # Always mounted too (Block N-enroll): server-driven SSH deploy reports
    # its own "not configured" state via a 400, and needs no enroll secret.
    app.include_router(deploy.router, tags=["enroll"])
    # Only mounted when enrollment is actually configured — an
    # unconfigured Bossman accepts no enrollments at all, matching the Go
    # Selecta's identical gating on proxy.enroll_secret.
    if settings.enroll_secret:
        app.include_router(enroll.router, tags=["enroll"])
    return app


app = create_app()
