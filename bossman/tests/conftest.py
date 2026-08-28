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

# Bossman's client keypair defaults to /etc/bossman/tls/, which the test user cannot write — any code
# path reaching ensure_client_keypair() dies with a bare PermissionError that says nothing about why.
# Individual tests used to monkeypatch this one at a time, which only helps the tests that already know
# they need it: the netboot checkin started minting a target identity and three unrelated tests broke.
# Pointing the whole suite at a temp dir removes the trap instead of documenting it. setdefault, so a
# test that wants its own path still wins.
import tempfile  # noqa: E402

_TEST_KEY_DIR = tempfile.mkdtemp(prefix="bossman-test-keys-")
os.environ.setdefault("BOSSMAN_CLIENT_KEY_PATH", os.path.join(_TEST_KEY_DIR, "bossman-client.key"))
os.environ.setdefault("BOSSMAN_CLIENT_CERT_PATH", os.path.join(_TEST_KEY_DIR, "bossman-client.crt"))

import uuid  # noqa: E402
from datetime import datetime, timedelta, timezone  # noqa: E402

import pytest  # noqa: E402
import pytest_asyncio  # noqa: E402
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine  # noqa: E402

from bossman.config import get_settings  # noqa: E402
from tests.naming import RUN_TAG  # noqa: E402


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
    # The residue guards deliberately live in the autouse fixture below, NOT here: a test that writes
    # through TestClient never asks for this fixture, so cleanup hanging off it cannot see what that
    # test created. One host leaked exactly that way (mon-85e29b3d) while this fixture already ran the
    # guards.


@pytest_asyncio.fixture(autouse=True)
async def _drop_test_residue():
    """Clean up after EVERY test, whether or not it asked for a database session.

    Autouse because the shared database is written by two different kinds of test: those taking
    `db_session`, and those going through `TestClient(create_app())`, which uses the app's own session
    and never touches this file's fixtures. Hanging cleanup off `db_session` only covered the first
    kind — measurably: with the guards attached there, a full run still leaked one host.

    Skips silently when there is no database, so the many tests that need none stay fast and green.
    """
    settings = get_settings()
    engine = create_async_engine(settings.database_url)
    try:
        async with engine.connect():
            pass
    except Exception:  # noqa: BLE001 — no database is not this fixture's problem
        await engine.dispose()
        yield
        return

    started = datetime.now(timezone.utc)
    yield
    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as session:
        await _drop_leaked_check_rules(session, started)
        await _drop_leaked_agents(session, started)
        await _drop_leaked_netboot_rows(session, started)
        await _drop_leaked_groups_and_grants(session, started)
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


# Test hosts are named <prefix>-<8 hex> by the suites' own helpers (mon-01c6a510, api-agent-00aee57a,
# poll-05433437, …). That shape is the signature: no real fleet host is named that way, and every one
# that exists was minted by a test.
_TEST_AGENT_NAME = r"^[a-z-]+-[0-9a-f]{8}$"

#: The ownership marker and the naming helper live in tests/naming.py so a suite can import them
#: without importing conftest (which pytest does not expose as a module). See that file for the
#: measurement that made ownership necessary: two concurrent runs deleted each other's rows.
#:
#: A row is cleaned when it is OWNED (its name carries this run's tag) or ORPHANED (test-shaped and
#: older than any plausible live run). A concurrent run's fresh rows are neither.
#:
#: Anything test-shaped and older than this belonged to a run that is long gone (a crash, a killed
#: container). No live suite runs for hours, so sweeping these cannot touch a running process.
_ORPHAN_AGE = timedelta(hours=2)

# Copied from _AGENT_CHILD_DELETES in bossman/api/agents.py so teardown cannot fall behind the schema.
_AGENT_CHILD_CLEANUP = (
    "DELETE FROM host_edges WHERE src_agent_id = ANY(:ids) OR dst_agent_id = ANY(:ids)",
    "DELETE FROM connection_events WHERE src_agent_id = ANY(:ids)",
    "DELETE FROM plan_runs WHERE agent_id = ANY(:ids)",
    "DELETE FROM downtimes WHERE agent_id = ANY(:ids)",
    "DELETE FROM service_state_history WHERE agent_id = ANY(:ids)",
    "DELETE FROM services WHERE agent_id = ANY(:ids)",
    "DELETE FROM metrics_raw WHERE series_id IN (SELECT series_id FROM metric_series WHERE agent_id = ANY(:ids))",
    "DELETE FROM metric_series WHERE agent_id = ANY(:ids)",
)


async def _drop_leaked_agents(session, started):
    """Remove any test host this test enrolled but did not clean up.

    The sibling of _drop_leaked_check_rules, and needed for the same reason: `enroll_agent` COMMITS,
    so the session rollback above does not undo it, and cleanup written at the end of a test body is
    skipped by a failed assertion.

    It is not cosmetic. Since L1 a host that does not report is DOWN and CRITICAL, so a leaked test
    host becomes a live problem that never clears. Measured on 2026-07-31 before this guard existed:
    386 leaked hosts accumulated over ten days, 294 of which had never reported, holding 162 open
    CRIT/WARN problems and burying the seven real hosts in the problem list.

    Bounded BOTH ways on purpose — the name shape and `created_at >= started` — so it can only ever
    remove something the current test just created. Pre-existing residue is deliberately left alone:
    cleaning that up is an operator decision, not a side effect of running the suite.
    """
    from sqlalchemy import text

    try:
        # OWNED (name carries this process's RUN_TAG) or ORPHANED (test-shaped and too old to
        # belong to any live run). `started` is no longer a criterion on its own: it could not tell
        # this run's rows from a concurrent run's, and deleted both — see RUN_TAG above.
        ids = list(
            (
                await session.scalars(
                    text(
                        "SELECT id FROM agents WHERE name LIKE :owned "
                        "OR (name ~ :pat AND created_at < :orphan_before)"
                    ).bindparams(
                        owned=f"%{RUN_TAG}%", pat=_TEST_AGENT_NAME,
                        orphan_before=datetime.now(timezone.utc) - _ORPHAN_AGE,
                    )
                )
            ).all()
        )
        if not ids:
            return
        params = {"ids": ids}
        # A cascade across compressed chunks would blow TimescaleDB's decompression cap and abort the
        # whole teardown; SET LOCAL keeps the lifted cap inside this transaction.
        await session.execute(text("SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0"))
        await session.execute(text("UPDATE agents SET parent_agent_id = NULL WHERE parent_agent_id = ANY(:ids)"), params)
        for stmt in _AGENT_CHILD_CLEANUP:
            await session.execute(text(stmt), params)
        await session.execute(text("DELETE FROM agents WHERE id = ANY(:ids)"), params)
        await session.commit()
    except Exception:  # noqa: BLE001 — teardown must never turn a passing test red
        await session.rollback()


async def _drop_leaked_groups_and_grants(session, started):
    """Remove host groups and access grants this run created.

    Both were missing from the guards and both were measured leaking into the shared database: 36
    `grp-XXXXXX` groups with no members polluted every group picker in the UI (including the new
    Check-templates link editor), and `access_grants` had grown to over a thousand rows. A leaked
    GROUP is not cosmetic either — a rule scoped to a group that only a test knows about is a
    policy nobody can explain.

    Same rule as the agents guard: owned by this run, or an orphan older than any live run.
    Groups cascade their memberships; a grant scoped to a deleted group goes with it.
    """
    from sqlalchemy import text

    try:
        params = {
            "owned": f"%{RUN_TAG}%",
            "grp": r"^grp-[0-9a-f]{6}$",
            "orphan_before": datetime.now(timezone.utc) - _ORPHAN_AGE,
        }
        # The test tokens themselves leak too (147 were sitting in the shared database). Same two
        # criteria: owned by this run, or an orphan whose name is unmistakably a suite's caller.
        await session.execute(
            text(
                "DELETE FROM api_tokens WHERE name LIKE :owned "
                "OR (name LIKE '%-caller%' AND created_at < :orphan_before)"
            ),
            params,
        )
        # TOKENS FIRST, then their grants — the order matters and the first version had it wrong.
        # Deleting grants before the tokens left every grant of a token removed in the same pass
        # behind, to be swept only on the NEXT run (measured: 1325 grants dropped to 971 instead of
        # going away). Removing the token first makes its grant dangle, and the grant sweep below
        # catches it immediately.
        #
        # The shape rule alone missed most of them, which measuring showed: 1325 grants existed and
        # only THREE matched `<prefix>-<8 hex>`, because the suites' callers use fixed names
        # (test-caller, mon-caller, mgmt-caller). So a grant is also swept when it DANGLES — no
        # api_tokens row carries its subject_ref — and its name looks like a test caller. Dangling
        # is not cosmetic: a grant references its subject by NAME, so a future token called
        # test-caller would inherit `scope=all, permission=manage` from a run that ended weeks ago.
        await session.execute(
            text(
                "DELETE FROM access_grants WHERE subject_ref LIKE :owned "
                "OR (subject_ref ~ '^[a-z-]+-[0-9a-f]{8}$' AND created_at < :orphan_before) "
                "OR (subject_kind = 'api_token' AND subject_ref LIKE '%-caller%' "
                "    AND NOT EXISTS (SELECT 1 FROM api_tokens t WHERE t.name = subject_ref))"
            ),
            params,
        )
        await session.execute(
            text(
                "DELETE FROM host_groups WHERE name LIKE :owned "
                "OR (name ~ :grp AND created_at < :orphan_before)"
            ),
            params,
        )
        await session.commit()
    except Exception:  # noqa: BLE001 — teardown must never turn a passing test red
        await session.rollback()


async def _drop_leaked_netboot_rows(session, started):
    """Remove disk images and restore jobs this test created but did not clean up.

    Third sibling of the guards above, and it earned its place immediately: three leftover restore jobs
    were enough to make `test_checkin_plans_the_restore_against_the_disk_the_target_reports` fail, by
    arming a second job for a MAC that already had one. Chasing that down surfaced a real bug in
    `netboot_checkin` (it picked the OLDEST armed job, so a stale job beat the one just armed), which is
    the useful half of the story — but the residue is what made the suite unreliable.

    Jobs before images, since a job references its image.
    """
    from sqlalchemy import text

    try:
        await session.execute(
            text("DELETE FROM restore_jobs WHERE created_at >= :since"), {"since": started}
        )
        await session.execute(
            text("DELETE FROM disk_images WHERE created_at >= :since"), {"since": started}
        )
        await session.commit()
    except Exception:  # noqa: BLE001 — teardown must never turn a passing test red
        await session.rollback()
