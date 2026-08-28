"""End-to-end tests for /api/v1/admin/* — the runtime operational control
plane (Block K2): diagnostics snapshot, live log-level switch, and an
on-demand housekeeping trigger. Real app + real DB (see
tests/conftest.py's db_session fixture, skips if no DB is reachable).
"""

import logging

from fastapi.testclient import TestClient

from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _make_api_token(db_session):
    row, raw = new_api_token("admin-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def test_diagnostics_requires_auth(db_session):
    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/admin/diagnostics")
    assert resp.status_code == 401


async def test_diagnostics_returns_poller_and_housekeeping_shape(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/admin/diagnostics", headers=_headers(raw))

    assert resp.status_code == 200
    body = resp.json()
    assert "log_level" in body
    assert body["db_pool_size"] >= 0
    assert set(body["poller"].keys()) == {"last_run_at", "last_run_duration_ms", "agents_polled", "agents_with_errors"}
    assert set(body["housekeeping"].keys()) == {"last_run_at", "last_run_duration_ms", "deleted", "last_error"}
    assert body["open_problems"] >= 0

    await db_session.delete(api_token)
    await db_session.commit()


async def test_set_log_level_changes_root_logger(db_session):
    api_token, raw = await _make_api_token(db_session)
    original = logging.getLogger().level

    with TestClient(create_app()) as client:
        resp = client.post("/api/v1/admin/log-level", json={"level": "debug"}, headers=_headers(raw))

    assert resp.status_code == 200
    assert resp.json()["level"] == "DEBUG"
    assert logging.getLogger().getEffectiveLevel() == logging.DEBUG

    logging.getLogger().setLevel(original)
    await db_session.delete(api_token)
    await db_session.commit()


async def test_set_log_level_rejects_invalid_level(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post("/api/v1/admin/log-level", json={"level": "NOPE"}, headers=_headers(raw))

    assert resp.status_code == 422

    await db_session.delete(api_token)
    await db_session.commit()


async def test_run_housekeeping_now_returns_deleted_counts(db_session):
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post("/api/v1/admin/housekeeping/run", headers=_headers(raw))

    assert resp.status_code == 200
    body = resp.json()
    # The sweep list lives in ONE place (tests/test_housekeeping.py) and is imported here. This
    # assertion used to hold its own copy and was three sweeps out of date — host_edges,
    # runbook_runs and audit_log had been added to the sweep and not to the copy, so the endpoint
    # test was red while the service test was green. Two copies of one fact is the defect; the
    # missing entries were only the symptom.
    from tests.test_housekeeping import ALWAYS_SWEEPS, OPTIONAL_SWEEPS

    keys = set(body["deleted"].keys())
    assert keys - OPTIONAL_SWEEPS == ALWAYS_SWEEPS
    assert keys <= ALWAYS_SWEEPS | OPTIONAL_SWEEPS

    await db_session.delete(api_token)
    await db_session.commit()
