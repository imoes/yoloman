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

from bossman.api import admin, agents, apps as apps_api, auth, capabilities as capabilities_api, chat, checks, document as document_api, docker_apps as docker_apps_api, helm_apps as helm_apps_api, resources as resources_api, systems as systems_api, scheduler as scheduler_api, events as events_api, rollouts as rollouts_api, compliance as compliance_api, audit as audit_api, business_services as business_services_api, forecast as forecast_api, config_sync as config_sync_api, chunks, clusters as clusters_api, config_codecs, config_directives, config_fields, config_templates, console, topology as topology_api, dashboard, deploy, deployments, devices, enroll, enroll_info, graphs, health, help, host_groups, images as images_api, management, modules, monitoring, notifications, orchestration, ou, package_catalog, package_wizard, plans, processes, relationships, runbooks, runs, search, security, severity_labels, sites, system_settings, templates, time_periods as time_periods_api, translate, users, value_maps, vm as vm_api
from bossman.config import get_settings
from bossman.db.session import make_engine
from bossman.mcp.auth import McpBearerAuthMiddleware
from bossman.mcp.server import build_mcp_server
from bossman.services import keys, plan_store
from bossman.services.catalog import CatalogCache
from bossman.services.cve_collect import collect_all_hosts
from bossman.services.cve_feed import CveFeed, CveFeedStats, cve_feed_loop
from bossman.services.chat_client import chat_client_for
from bossman.services.chat_oauth import ChatOAuthService
from bossman.services.embedding_client import embedding_client_for
from bossman.services.housekeeping import HousekeepingStats, housekeeping_loop, process_prune_loop
from bossman.services.monitoring import mark_poller_agent, seed_default_check_rules
from bossman.services.wizard_seed import seed_wizard_runbooks, wizard_reseed_loop
from bossman.services.poller import PollerStats, poller_loop
from bossman.services.scheduler import scheduler_loop
from bossman.services.event_console import event_console_loop
from bossman.services.capabilities import capabilities_loop
from bossman.services.compliance import compliance_loop
from bossman.services.audit import audit_middleware
from bossman.services.business_service import business_service_loop
from bossman.services.reconciler import ConvergeStats, ReconcileStats, converge_loop, reconciler_loop

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

    # Mark the co-located SNMP/SSH poller as a hidden proxy ("selecta") so it
    # runs silently and doesn't clutter the Hosts/fleet views — it exists only
    # to poll agent-less devices on their behalf. Idempotent.
    async with app.state.session_factory() as session:
        await mark_poller_agent(session, settings.poller_agent_name)

    # Seed the helm chart-pull proxy cache from the DB-backed SystemSettings so
    # `helm show/pull` uses it from the first request (it is edited in Admin
    # Settings, not via env — see api/system_settings.py). Best-effort: a missing
    # row / pre-migration DB just leaves the default no-proxy posture.
    try:
        from uuid import UUID as _UUID

        from bossman.db.models import SYSTEM_SETTINGS_ID, SystemSettings
        from bossman.services import helm_app

        async with app.state.session_factory() as session:
            row = await session.get(SystemSettings, _UUID(SYSTEM_SETTINGS_ID))
            if row is not None:
                helm_app.set_helm_proxy(row.helm_http_proxy, row.helm_no_proxy)
    except Exception:  # noqa: BLE001 — never let proxy seeding break startup
        logger.warning("helm proxy cache seeding failed at startup", exc_info=True)

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

    # Installation-wizard runbooks (folder "wizards"): one install-<pkg> per
    # catalog package with a template. Idempotent hash-upsert; best-effort.
    async with app.state.session_factory() as session:
        try:
            n = await seed_wizard_runbooks(session, settings)
            if n:
                logger.info("seeded wizard runbooks", extra={"changed": n})
        except Exception:  # noqa: BLE001 — never let wizard seeding break startup
            await session.rollback()
            logger.warning("wizard runbook seeding failed at startup", exc_info=True)

    app.state.catalog_cache = CatalogCache(settings.plans_dir)
    app.state.embedding_client = embedding_client_for(settings)
    app.state.chat_client = chat_client_for(settings)
    app.state.chat_oauth = ChatOAuthService()
    # In-memory progress for running discovery jobs (percent bar); see services/discovery_jobs.py.
    from bossman.services.discovery_jobs import DiscoveryJobs

    app.state.discovery_jobs = DiscoveryJobs()

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
    # Block 4: CVE feed cache — index distro security trackers so pending
    # package updates can be correlated to the CVEs they fix. Warm from the
    # on-disk cache immediately so lookups work before the first refresh.
    app.state.cve_feed_stats = CveFeedStats()
    app.state.cve_feed = CveFeed(settings, app.state.cve_feed_stats)
    app.state.cve_feed.load_from_cache()
    # Block L4: the desired-state reconciler drains controller_outbox,
    # recompiles affected hosts and enqueues agent_config_delivery rows.
    app.state.reconcile_stats = ReconcileStats()

    stop_event = asyncio.Event()
    poller_task = asyncio.create_task(poller_loop(app.state.session_factory, settings, stop_event, app.state.poller_stats))
    process_prune_task = asyncio.create_task(
        process_prune_loop(app.state.session_factory, settings, stop_event)
    )
    housekeeping_task = asyncio.create_task(
        housekeeping_loop(app.state.session_factory, settings, stop_event, app.state.housekeeping_stats)
    )
    reconciler_task = asyncio.create_task(
        reconciler_loop(app.state.session_factory, settings, stop_event, app.state.reconcile_stats)
    )
    app.state.converge_stats = ConvergeStats()
    converge_task = asyncio.create_task(
        converge_loop(app.state.session_factory, settings, stop_event, app.state.converge_stats)
    )
    async def _collect_cves() -> None:
        await collect_all_hosts(app.state.session_factory, settings, app.state.cve_feed)

    cve_feed_task = asyncio.create_task(
        cve_feed_loop(app.state.cve_feed, settings, stop_event, after_refresh=_collect_cves)
    )
    # Re-seed wizard runbooks as the template batch grows the catalog.
    wizard_task = asyncio.create_task(wizard_reseed_loop(app.state.session_factory, settings, stop_event))
    # Recurring-runbook scheduler (gap #7): fire ScheduledJobs on their cron.
    scheduler_task = asyncio.create_task(scheduler_loop(app.state.session_factory, settings, stop_event))
    # Event Console (gap #2): passive syslog + SNMP-trap UDP listeners.
    event_console_task = asyncio.create_task(event_console_loop(app.state.session_factory, settings, stop_event))
    # Software compliance (gap #9): required/forbidden packages per scope, alert on drift.
    compliance_task = asyncio.create_task(compliance_loop(app.state.session_factory, settings, stop_event))
    # Lego capability inventory: derive host_capabilities from installed roles x per-template contracts.
    capabilities_task = asyncio.create_task(capabilities_loop(app.state.session_factory, settings, stop_event))
    # Business/logical service aggregation (gap #4): roll up state from many services.
    business_service_task = asyncio.create_task(business_service_loop(app.state.session_factory, settings, stop_event))
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
        process_prune_task.cancel()
        reconciler_task.cancel()
        converge_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await converge_task
        cve_feed_task.cancel()
        wizard_task.cancel()
        scheduler_task.cancel()
        event_console_task.cancel()
        compliance_task.cancel()
        capabilities_task.cancel()
        business_service_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await business_service_task
        with contextlib.suppress(asyncio.CancelledError):
            await scheduler_task
        with contextlib.suppress(asyncio.CancelledError):
            await event_console_task
        with contextlib.suppress(asyncio.CancelledError):
            await compliance_task
        with contextlib.suppress(asyncio.CancelledError):
            await capabilities_task
        with contextlib.suppress(asyncio.CancelledError):
            await poller_task
        with contextlib.suppress(asyncio.CancelledError):
            await housekeeping_task
            await process_prune_task
        with contextlib.suppress(asyncio.CancelledError):
            await reconciler_task
        with contextlib.suppress(asyncio.CancelledError):
            await cve_feed_task
        with contextlib.suppress(asyncio.CancelledError):
            await wizard_task
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
    # Audit trail (gap #13): record every authenticated mutating API call.
    app.middleware("http")(audit_middleware)
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
    app.include_router(console.router, tags=["console"])
    app.include_router(topology_api.router, tags=["topology"])
    app.include_router(processes.router, tags=["processes"])
    app.include_router(management.router, tags=["management"])
    app.include_router(chat.router, tags=["chat"])
    app.include_router(users.router, tags=["users"])
    app.include_router(relationships.router, tags=["relationships"])
    app.include_router(plans.router, tags=["plans"])
    app.include_router(runs.router, tags=["runs"])
    app.include_router(chunks.router, tags=["chunks"])
    app.include_router(translate.router, tags=["translate"])
    app.include_router(monitoring.router, tags=["monitoring"])
    app.include_router(dashboard.router, tags=["dashboard"])
    app.include_router(modules.router, tags=["modules"])
    app.include_router(checks.router, tags=["checks"])
    app.include_router(help.router, tags=["help"])
    app.include_router(runbooks.router, tags=["runbooks"])
    app.include_router(deployments.router, tags=["deployments"])
    app.include_router(notifications.router, tags=["notifications"])
    app.include_router(time_periods_api.router, tags=["time-periods"])
    app.include_router(clusters_api.router, tags=["clusters"])
    app.include_router(images_api.router, tags=["images"])
    app.include_router(vm_api.router, tags=["vm"])
    app.include_router(scheduler_api.router, tags=["scheduler"])
    app.include_router(events_api.router, tags=["events"])
    app.include_router(rollouts_api.router, tags=["rollouts"])
    app.include_router(compliance_api.router, tags=["compliance"])
    app.include_router(audit_api.router, tags=["audit"])
    app.include_router(business_services_api.router, tags=["business-services"])
    app.include_router(forecast_api.router, tags=["forecast"])
    app.include_router(config_sync_api.router, tags=["config-sync"])
    app.include_router(admin.router, tags=["admin"])
    app.include_router(value_maps.router, tags=["value-maps"])
    app.include_router(config_templates.router, tags=["config-templates"])
    app.include_router(config_codecs.router, tags=["config-codecs"])
    app.include_router(apps_api.router, tags=["apps"])
    app.include_router(document_api.router, tags=["document"])
    app.include_router(docker_apps_api.router, tags=["docker"])
    app.include_router(helm_apps_api.router, tags=["helm"])
    app.include_router(systems_api.router, tags=["systems"])
    app.include_router(resources_api.router, tags=["resources"])
    app.include_router(package_catalog.router, tags=["package-catalog"])
    app.include_router(package_wizard.router, tags=["package-wizard"])
    app.include_router(capabilities_api.router, tags=["capabilities"])
    app.include_router(config_directives.router, tags=["config-directives"])
    app.include_router(config_fields.router, tags=["config-fields"])
    app.include_router(devices.router, tags=["devices"])
    app.include_router(search.router, tags=["search"])
    app.include_router(severity_labels.router, tags=["severity-labels"])
    app.include_router(graphs.router, tags=["graphs"])
    app.include_router(templates.router, tags=["templates"])
    app.include_router(ou.router, tags=["ou"])
    app.include_router(host_groups.router, tags=["host-groups"])
    app.include_router(sites.router, tags=["sites"])
    app.include_router(orchestration.router, tags=["orchestration"])
    app.include_router(system_settings.router, tags=["system-settings"])
    app.include_router(security.router, tags=["security"])
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
    # Enrollment is open (no secret) — always mounted.
    app.include_router(enroll.router, tags=["enroll"])
    return app


app = create_app()
