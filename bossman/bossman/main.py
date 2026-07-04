"""Bossman — Fleet Commander for agentic-mcpd ("Duppy") node agents.

App factory pattern (create_app), not a module-level singleton: keeps the
app trivially constructible in tests without needing the real lifespan
(DB pool, poller task) to run — see tests/test_health.py.
"""

from contextlib import asynccontextmanager

from fastapi import FastAPI

from bossman.api import health
from bossman.config import get_settings


@asynccontextmanager
async def lifespan(app: FastAPI):
    # DB pool / background poller task wiring lands here in a later block
    # (see docs/plan.md's Bossman Block B4) — deliberately absent for now
    # so the bare scaffold is testable without a real Postgres instance.
    yield


def create_app() -> FastAPI:
    get_settings()  # fail fast on invalid configuration
    app = FastAPI(title="Bossman", lifespan=lifespan)
    # Bare /healthz, no /api/v1 prefix — matches the Go node agent's own
    # convention (an unauthenticated liveness check needs no API versioning).
    app.include_router(health.router, tags=["health"])
    return app


app = create_app()
