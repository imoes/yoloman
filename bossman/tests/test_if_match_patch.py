"""`If-Match` on the PARTIAL edits — the half that was missing.

Every PUT in this API honoured `If-Match` (check rules, notification rules, time periods, clusters,
event handlers). Both PATCH routes did not, which is the wrong way round: a partial edit is where a
lost update is most likely, because two people changing *different* fields of one rule each believe
they are safe, and neither is warned.

The contract these tests pin down — deliberately not "every write needs a header", which would break
existing callers (see api/etag.py for why it is honoured-when-present):

  * a caller that sends a CURRENT version writes normally,
  * a caller that sends a STALE version is refused with 412 and told to re-read,
  * a caller that sends no header at all still writes.
"""

from fastapi.testclient import TestClient

from bossman.config import get_settings
from bossman.db.models import CheckRule, NotificationRule
from bossman.main import create_app
from bossman.services.auth import create_access_token, new_bossman_user
from tests.naming import owned_name


async def _admin(db_session):
    u = new_bossman_user(owned_name("ifm"), "pw", "admin")
    db_session.add(u)
    await db_session.commit()
    return {"Authorization": f"Bearer {create_access_token(u, get_settings())}"}


async def _check_rule(db_session):
    # Same construction as tests/test_gpo.py — the columns this model actually has.
    r = CheckRule(service_name=owned_name("cpu"), metric="cpu_pct", comparison="gt",
                  warn_threshold=80.0, crit_threshold=95.0, scope_type="global")
    db_session.add(r)
    await db_session.commit()
    return r


async def _notification_rule(db_session):
    r = NotificationRule(name=owned_name("nr"), channel="email", target="x@example.com",
                         scope_type="global")
    db_session.add(r)
    await db_session.commit()
    return r


async def test_check_rule_patch_honours_if_match(db_session):
    headers = await _admin(db_session)
    rule = await _check_rule(db_session)
    with TestClient(create_app()) as client:
        listed = client.get("/api/v1/check-rules", headers=headers)
        assert listed.status_code == 200
        current = next(r["version"] for r in listed.json() if r["id"] == str(rule.id))

        # A stale version is refused, and the reason names what to do about it.
        stale = client.patch(f"/api/v1/check-rules/{rule.id}", json={"enabled": False},
                             headers=headers | {"If-Match": "0000000000000000"})
        assert stale.status_code == 412
        assert "re-read" in stale.json()["detail"]

        # The current version writes.
        ok = client.patch(f"/api/v1/check-rules/{rule.id}", json={"enabled": False},
                          headers=headers | {"If-Match": current})
        assert ok.status_code == 200 and ok.json()["enabled"] is False

        # No header at all still writes — the guarantee is for clients that send one.
        bare = client.patch(f"/api/v1/check-rules/{rule.id}", json={"enabled": True}, headers=headers)
        assert bare.status_code == 200 and bare.json()["enabled"] is True

    await db_session.delete(rule)
    await db_session.commit()


async def test_notification_rule_patch_honours_if_match(db_session):
    headers = await _admin(db_session)
    rule = await _notification_rule(db_session)
    with TestClient(create_app()) as client:
        stale = client.patch(f"/api/v1/notification-rules/{rule.id}", json={"enabled": False},
                             headers=headers | {"If-Match": "0000000000000000"})
        assert stale.status_code == 412
        bare = client.patch(f"/api/v1/notification-rules/{rule.id}", json={"enabled": False},
                            headers=headers)
        assert bare.status_code == 200

    await db_session.delete(rule)
    await db_session.commit()
