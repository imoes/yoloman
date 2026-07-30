"""L4 CRUD surface. Validation happens on WRITE, because the place a bad definition
goes wrong is the notification path, where the symptom is a page that never arrives.
"""

import uuid

from fastapi.testclient import TestClient
from sqlalchemy import delete, select

from bossman.db.models import AccessGrant, NotificationRule, TimePeriod
from bossman.main import create_app
from bossman.services.auth import new_api_token

BUSINESS = {d: [["08:00", "17:00"]] for d in ("monday", "tuesday", "wednesday", "thursday", "friday")}


async def _make_api_token(db_session):
    name = f"tp-caller-{uuid.uuid4().hex[:6]}"
    row, raw = new_api_token(name)
    db_session.add(row)
    db_session.add(AccessGrant(subject_kind="api_token", subject_ref=name, scope="all"))
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


async def _cleanup(db_session, *names, token=None):
    if names:
        await db_session.execute(delete(TimePeriod).where(TimePeriod.name.in_(names)))
    if token is not None:
        await db_session.delete(token)
    await db_session.commit()


async def test_the_builtin_always_exists_and_reports_active(db_session):
    """Seeded by the migration; `active_now` is what makes the feature debuggable."""
    token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.get("/api/v1/time-periods", headers=_headers(raw))
    assert resp.status_code == 200
    always = next(p for p in resp.json() if p["name"] == "24x7")
    assert always["is_builtin"] is True
    assert always["active_now"] is True, "24x7 is active by definition, at every hour"
    await _cleanup(db_session, token=token)


async def test_create_and_read_back(db_session):
    token, raw = await _make_api_token(db_session)
    name = f"business-{uuid.uuid4().hex[:6]}"
    with TestClient(create_app()) as client:
        created = client.post(
            "/api/v1/time-periods",
            json={"name": name, "alias": "Business hours", "ranges": BUSINESS},
            headers=_headers(raw),
        )
        assert created.status_code == 201, created.text
        listed = client.get("/api/v1/time-periods", headers=_headers(raw)).json()

    mine = next(p for p in listed if p["name"] == name)
    assert mine["ranges"]["monday"] == [["08:00", "17:00"]]
    assert mine["is_builtin"] is False
    await _cleanup(db_session, name, token=token)


async def test_a_typoed_weekday_is_refused_on_write(db_session):
    """It would otherwise be stored as a window that silently never matches."""
    token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/time-periods",
            json={"name": f"typo-{uuid.uuid4().hex[:6]}", "ranges": {"tuseday": [["08:00", "17:00"]]}},
            headers=_headers(raw),
        )
    assert resp.status_code == 422
    assert "tuseday" in resp.text
    await _cleanup(db_session, token=token)


async def test_an_inverted_span_is_refused(db_session):
    token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/time-periods",
            json={"name": f"night-{uuid.uuid4().hex[:6]}", "ranges": {"monday": [["22:00", "02:00"]]}},
            headers=_headers(raw),
        )
    assert resp.status_code == 422
    await _cleanup(db_session, token=token)


async def test_a_duplicate_name_is_a_conflict(db_session):
    token, raw = await _make_api_token(db_session)
    name = f"dup-{uuid.uuid4().hex[:6]}"
    with TestClient(create_app()) as client:
        first = client.post("/api/v1/time-periods", json={"name": name, "ranges": BUSINESS}, headers=_headers(raw))
        second = client.post("/api/v1/time-periods", json={"name": name, "ranges": BUSINESS}, headers=_headers(raw))
    assert first.status_code == 201
    assert second.status_code == 409
    await _cleanup(db_session, name, token=token)


async def test_excluding_an_unknown_period_is_refused(db_session):
    """A dangling exclude makes the period unevaluable — and the dispatcher then treats it
    as unrestricted, i.e. the exclusion silently stops applying."""
    token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/time-periods",
            json={"name": f"x-{uuid.uuid4().hex[:6]}", "ranges": BUSINESS, "excludes": ["ghost"]},
            headers=_headers(raw),
        )
    assert resp.status_code == 422
    assert "ghost" in resp.text
    await _cleanup(db_session, token=token)


async def test_self_exclusion_is_refused(db_session):
    token, raw = await _make_api_token(db_session)
    name = f"self-{uuid.uuid4().hex[:6]}"
    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/time-periods",
            json={"name": name, "ranges": BUSINESS, "excludes": [name]},
            headers=_headers(raw),
        )
    assert resp.status_code == 422
    await _cleanup(db_session, name, token=token)


async def test_the_builtin_cannot_be_deleted(db_session):
    token, raw = await _make_api_token(db_session)
    always = await db_session.scalar(select(TimePeriod).where(TimePeriod.name == "24x7"))
    with TestClient(create_app()) as client:
        resp = client.delete(f"/api/v1/time-periods/{always.id}", headers=_headers(raw))
    assert resp.status_code == 409
    assert await db_session.scalar(select(TimePeriod).where(TimePeriod.name == "24x7")) is not None
    await _cleanup(db_session, token=token)


async def test_a_referenced_period_cannot_be_deleted_or_renamed(db_session):
    """excludes reference by NAME, so both operations would dangle the reference."""
    token, raw = await _make_api_token(db_session)
    holidays = f"holidays-{uuid.uuid4().hex[:6]}"
    business = f"business-{uuid.uuid4().hex[:6]}"
    with TestClient(create_app()) as client:
        h = client.post("/api/v1/time-periods", json={"name": holidays, "ranges": {}}, headers=_headers(raw))
        client.post(
            "/api/v1/time-periods",
            json={"name": business, "ranges": BUSINESS, "excludes": [holidays]},
            headers=_headers(raw),
        )
        deleted = client.delete(f"/api/v1/time-periods/{h.json()['id']}", headers=_headers(raw))
        renamed = client.put(
            f"/api/v1/time-periods/{h.json()['id']}",
            json={"name": f"{holidays}-renamed", "ranges": {}},
            headers=_headers(raw),
        )
    assert deleted.status_code == 409 and business in deleted.text
    assert renamed.status_code == 409 and business in renamed.text
    await _cleanup(db_session, holidays, business, token=token)


async def test_usage_lists_the_rules_that_would_be_affected(db_session):
    """Asked before editing a window, not discovered afterwards."""
    token, raw = await _make_api_token(db_session)
    name = f"usage-{uuid.uuid4().hex[:6]}"
    with TestClient(create_app()) as client:
        created = client.post("/api/v1/time-periods", json={"name": name, "ranges": BUSINESS}, headers=_headers(raw))
        pid = created.json()["id"]
        rule = NotificationRule(
            name=f"rule-{uuid.uuid4().hex[:6]}", channel="email", target="ops@example.com",
            time_period_id=uuid.UUID(pid),
        )
        db_session.add(rule)
        await db_session.commit()
        usage = client.get(f"/api/v1/time-periods/{pid}/usage", headers=_headers(raw)).json()

    assert [r["name"] for r in usage["notification_rules"]] == [rule.name]
    await db_session.delete(rule)
    await db_session.commit()
    await _cleanup(db_session, name, token=token)


async def test_deleting_a_window_widens_its_rules_back_to_always(db_session):
    """ON DELETE SET NULL: cleanup must not silently delete someone's alerting."""
    token, raw = await _make_api_token(db_session)
    name = f"widen-{uuid.uuid4().hex[:6]}"
    with TestClient(create_app()) as client:
        created = client.post("/api/v1/time-periods", json={"name": name, "ranges": BUSINESS}, headers=_headers(raw))
        pid = created.json()["id"]
        rule = NotificationRule(
            name=f"rule-{uuid.uuid4().hex[:6]}", channel="email", target="ops@example.com",
            time_period_id=uuid.UUID(pid),
        )
        db_session.add(rule)
        await db_session.commit()
        assert client.delete(f"/api/v1/time-periods/{pid}", headers=_headers(raw)).status_code == 204

    await db_session.refresh(rule)
    assert rule.time_period_id is None, "the rule must still exist, unrestricted"
    await db_session.delete(rule)
    await db_session.commit()
    await _cleanup(db_session, token=token)


async def test_a_rule_cannot_point_at_a_nonexistent_window(db_session):
    token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/notification-rules",
            json={
                "name": f"r-{uuid.uuid4().hex[:6]}", "channel": "email", "target": "ops@example.com",
                "time_period_id": str(uuid.uuid4()),
            },
            headers=_headers(raw),
        )
    assert resp.status_code == 422
    assert "time period" in resp.text
    await _cleanup(db_session, token=token)
