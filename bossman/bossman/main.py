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

from bossman.api import enroll, health
from bossman.config import get_settings
from bossman.db.session import make_engine
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

    stop_event = asyncio.Event()
    poller_task = asyncio.create_task(poller_loop(app.state.session_factory, settings, stop_event))
    try:
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
    # Only mounted when enrollment is actually configured — an
    # unconfigured Bossman accepts no enrollments at all, matching the Go
    # Selecta's identical gating on proxy.enroll_secret.
    if settings.enroll_secret:
        app.include_router(enroll.router, tags=["enroll"])
    return app


app = create_app()
