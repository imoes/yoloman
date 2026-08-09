"""Async SQLAlchemy engine/session factory, and the FastAPI dependency
that hands request handlers a session.

The engine is deliberately NOT a module-level singleton (an earlier
version was) — a real, DB-backed test using two separate `TestClient`
instances against two separately-constructed apps surfaced
`RuntimeError: ... got Future ... attached to a different loop`: each
`TestClient` spins up its own event loop, and a pooled asyncpg connection
created under one loop cannot be reused under another. The fix is to bind
the engine's lifetime to the FastAPI app instance (created fresh in
`bossman.main`'s lifespan, disposed on shutdown) rather than to the Python
process — see docs/plan.md's Bossman Block B4 note this was always meant
to land in the lifespan, just not exercised until a DB-backed HTTP test
existed.
"""

from collections.abc import AsyncGenerator

from fastapi import Request
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine


def make_engine(database_url: str) -> AsyncEngine:
    return create_async_engine(database_url, pool_pre_ping=True)


async def get_session(request: Request) -> AsyncGenerator[AsyncSession]:
    session_factory: async_sessionmaker[AsyncSession] = request.app.state.session_factory
    async with session_factory() as session:
        yield session
