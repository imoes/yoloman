"""Bossman — Fleet Commander for agentic-mcpd ("Duppy") node agents.

App factory pattern (create_app), not a module-level singleton: keeps the
app trivially constructible in tests without needing the real lifespan
(DB pool, poller task) to run — see tests/test_health.py.
"""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from sqlalchemy.ext.asyncio import async_sessionmaker

from bossman.api import enroll, health
from bossman.config import get_settings
from bossman.db.session import make_engine


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Engine lifetime is bound to this app instance, not the process — see
    # bossman/db/session.py's docstring for why a module-level singleton
    # broke across multiple event loops in tests (and would equally break
    # in production if the process ever hosted more than one app/loop).
    settings = get_settings()
    engine = make_engine(settings.database_url)
    app.state.session_factory = async_sessionmaker(engine, expire_on_commit=False)
    try:
        yield
    finally:
        await engine.dispose()
    # Background poller task wiring lands here in a later block (see
    # docs/plan.md's Bossman Block B4).


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
