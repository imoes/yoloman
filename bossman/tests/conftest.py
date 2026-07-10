import os

# Tests share one real database; the Block-H6 default-rule seeding runs in
# create_app()'s lifespan (any TestClient triggers it) and would leave
# global Memory/Disk rules behind, polluting count-based assertions in the
# monitoring/poller tests. Disable it for the suite (set before Settings is
# constructed). Production keeps the default (True).
os.environ.setdefault("BOSSMAN_SEED_DEFAULT_CHECKS", "false")

# Every TestClient(create_app()) triggers the real lifespan, including the
# background poller/housekeeping loops. Letting those run for real during
# every API test means genuine concurrent DB/network work racing the
# test's own db_session on the same event loop — a real, reproducible
# sqlalchemy.exc.MissingGreenlet found while adding Block K11's tests, not
# a hypothetical concern. Tests that exercise poll_once/poll_agent or
# run_housekeeping directly (test_poller.py, test_housekeeping.py) call
# them explicitly and are unaffected by the background loop being quiet.
# Production keeps both defaults (True).
os.environ.setdefault("BOSSMAN_POLL_ENABLED", "false")
os.environ.setdefault("BOSSMAN_HOUSEKEEPING_ENABLED", "false")
os.environ.setdefault("BOSSMAN_RECONCILE_ENABLED", "false")
# A non-empty JWT secret so tests that mint an operator/admin token (Block M
# ACL) can sign/verify (HS256 rejects an empty key).
os.environ.setdefault("BOSSMAN_JWT_SECRET", "test-jwt-secret-block-m-000000000")

import pytest  # noqa: E402
import pytest_asyncio  # noqa: E402
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine  # noqa: E402

from bossman.config import get_settings  # noqa: E402


@pytest_asyncio.fixture
async def db_session():
    """A real async session against the configured database — skips the
    test entirely if that database isn't reachable (e.g. no dev Postgres
    running), rather than mocking the DB away. See bossman/README.md for
    how to start one locally."""
    settings = get_settings()
    engine = create_async_engine(settings.database_url)
    try:
        async with engine.connect():
            pass
    except Exception as exc:  # noqa: BLE001 - deliberately broad: any connection failure means "skip"
        await engine.dispose()
        pytest.skip(f"no reachable database at {settings.database_url!r}: {exc}")

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as session:
        yield session
        await session.rollback()  # never leave test data behind
    await engine.dispose()
