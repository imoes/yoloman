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
os.environ.setdefault("BOSSMAN_CONFIG_SYNC_ENABLED", "false")
os.environ.setdefault("BOSSMAN_COMPLIANCE_ENABLED", "false")
os.environ.setdefault("BOSSMAN_AUDIT_ENABLED", "false")
os.environ.setdefault("BOSSMAN_BUSINESS_SERVICE_ENABLED", "false")
# A non-empty JWT secret so tests that mint an operator/admin token (Block M
# ACL) can sign/verify (HS256 rejects an empty key).
os.environ.setdefault("BOSSMAN_JWT_SECRET", "test-jwt-secret-block-m-000000000")

from datetime import datetime, timezone  # noqa: E402

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
    started = datetime.now(timezone.utc)
    async with session_factory() as session:
        yield session
        await session.rollback()  # never leave test data behind
        await _drop_leaked_check_rules(session, started)
    await engine.dispose()


async def _drop_leaked_check_rules(session, started):
    """Remove any non-default CheckRule this test created but did not clean up.

    The tests share the database with the RUNNING system, and their cleanup lives at the
    end of the test body — so a failed assertion skips it and the rule stays. That is not
    only untidy: a global rule applies to every host, so a leaked test threshold becomes
    live monitoring policy. It happened — a test's "Memory CRIT at 20%" leaked and the
    poller promptly raised CRIT on all four production hosts. A single run had left 45
    stray rules behind, 30 of them copies of the same CPU rule.

    is_default rules are spared: those are the real seeded defaults, not test data.
    services.rule_id is nulled first (FK), which costs nothing — the next evaluation
    re-attaches the winning rule anyway.
    """
    from sqlalchemy import delete, null, select, update

    from bossman.db.models import CheckRule, Service

    try:
        leaked = list(
            (
                await session.scalars(
                    select(CheckRule.id).where(
                        CheckRule.created_at >= started,
                        CheckRule.is_default == False,  # noqa: E712
                    )
                )
            ).all()
        )
        if not leaked:
            return
        await session.execute(update(Service).where(Service.rule_id.in_(leaked)).values(rule_id=null()))
        await session.execute(delete(CheckRule).where(CheckRule.id.in_(leaked)))
        await session.commit()
    except Exception:  # noqa: BLE001 — teardown must never turn a passing test red
        await session.rollback()
