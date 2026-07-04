"""Async SQLAlchemy engine/session, and the FastAPI dependency that hands
request handlers a session — see docs/plan.md's Bossman design ("async
everywhere... blocking DB calls would serialize the event loop")."""

from collections.abc import AsyncGenerator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from bossman.config import get_settings

_engine = create_async_engine(get_settings().database_url, pool_pre_ping=True)
_session_factory = async_sessionmaker(_engine, expire_on_commit=False)


async def get_session() -> AsyncGenerator[AsyncSession]:
    async with _session_factory() as session:
        yield session
