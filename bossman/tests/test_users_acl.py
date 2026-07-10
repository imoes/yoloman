"""Block M — ACL helper, route enforcement, and the users/grants admin API."""

import uuid

from fastapi.testclient import TestClient

from bossman.config import get_settings
from bossman.db.models import AccessGrant, Agent, HostGroup, HostGroupMember
from bossman.main import create_app
from bossman.services.auth import Identity, create_access_token, new_api_token, new_bossman_user, user_can_manage_agent

DEFAULT_TENANT = uuid.UUID("00000000-0000-0000-0000-000000000001")


async def _agent(db_session, **kw):
    fields = {"name": f"acl-{uuid.uuid4().hex[:8]}", "token": "t", "mode": "standalone", "enrollment_state": "enrolled",
              "address": "10.0.0.9:8010"}
    fields.update(kw)
    a = Agent(**fields)
    db_session.add(a)
    await db_session.flush()
    await db_session.commit()
    return a


async def _user(db_session, role="operator"):
    u = new_bossman_user(f"u-{uuid.uuid4().hex[:6]}", "pw", role)
    db_session.add(u)
    await db_session.flush()
    await db_session.commit()
    return u


def _jwt(user):
    return create_access_token(user, get_settings())


def _h(tok):
    return {"Authorization": f"Bearer {tok}"}


# ---- helper unit ----


async def test_admin_bypasses(db_session):
    a = await _agent(db_session)
    ident = Identity(kind="user", name="root", role="admin")
    assert await user_can_manage_agent(db_session, ident, a.id) is True
    await db_session.delete(a)
    await db_session.commit()


async def test_operator_without_grant_denied(db_session):
    a = await _agent(db_session)
    ident = Identity(kind="user", name="opX", role="operator")
    assert await user_can_manage_agent(db_session, ident, a.id) is False
    await db_session.delete(a)
    await db_session.commit()


async def test_host_grant_allows(db_session):
    a = await _agent(db_session)
    g = AccessGrant(subject_kind="user", subject_ref="opX", scope="host", agent_id=a.id)
    db_session.add(g)
    await db_session.commit()
    ident = Identity(kind="user", name="opX", role="operator")
    assert await user_can_manage_agent(db_session, ident, a.id) is True
    # a different host is still denied
    other = await _agent(db_session)
    assert await user_can_manage_agent(db_session, ident, other.id) is False
    await db_session.delete(g)
    await db_session.delete(a)
    await db_session.delete(other)
    await db_session.commit()


async def test_all_grant_allows_token(db_session):
    a = await _agent(db_session)
    g = AccessGrant(subject_kind="api_token", subject_ref="ci", scope="all")
    db_session.add(g)
    await db_session.commit()
    ident = Identity(kind="api_token", name="ci")
    assert await user_can_manage_agent(db_session, ident, a.id) is True
    # a token WITHOUT the grant is denied
    assert await user_can_manage_agent(db_session, Identity(kind="api_token", name="other"), a.id) is False
    await db_session.delete(g)
    await db_session.delete(a)
    await db_session.commit()


async def test_group_grant_via_membership(db_session):
    a = await _agent(db_session)
    hg = HostGroup(tenant_id=DEFAULT_TENANT, name=f"grp-{uuid.uuid4().hex[:6]}")
    db_session.add(hg)
    await db_session.flush()
    db_session.add(HostGroupMember(tenant_id=DEFAULT_TENANT, host_group_id=hg.id, agent_id=a.id))
    db_session.add(AccessGrant(subject_kind="user", subject_ref="opG", scope="host_group", host_group_id=hg.id))
    await db_session.commit()
    ident = Identity(kind="user", name="opG", role="operator")
    assert await user_can_manage_agent(db_session, ident, a.id) is True
    await db_session.commit()


# ---- route enforcement ----


async def test_service_route_403_for_ungranted_operator(db_session):
    a = await _agent(db_session)
    op = await _user(db_session, "operator")
    with TestClient(create_app()) as client:
        r = client.get(f"/api/v1/agents/{a.id}/services", headers=_h(_jwt(op)))
        assert r.status_code == 403
    await db_session.delete(a)
    await db_session.commit()


async def test_admin_not_403(db_session):
    a = await _agent(db_session, address=None)  # no address -> 422 from handler, not 403
    admin = await _user(db_session, "admin")
    with TestClient(create_app()) as client:
        r = client.get(f"/api/v1/agents/{a.id}/services", headers=_h(_jwt(admin)))
        assert r.status_code != 403
    await db_session.delete(a)
    await db_session.commit()


# ---- users/grants admin API ----


async def test_users_api_admin_only(db_session):
    op = await _user(db_session, "operator")
    admin = await _user(db_session, "admin")
    with TestClient(create_app()) as client:
        assert client.get("/api/v1/users", headers=_h(_jwt(op))).status_code == 403
        assert client.get("/api/v1/users", headers=_h(_jwt(admin))).status_code == 200
        # create a user + grant it a host
        cu = client.post("/api/v1/users", json={"username": f"nu-{uuid.uuid4().hex[:5]}", "password": "pw", "role": "operator"}, headers=_h(_jwt(admin)))
        assert cu.status_code == 200
        gid = client.post("/api/v1/access-grants", json={"subject_kind": "user", "subject_ref": cu.json()["username"], "scope": "all"}, headers=_h(_jwt(admin)))
        assert gid.status_code == 200
        # /me reflects the operator's own (empty) grants
        me = client.get("/api/v1/me", headers=_h(_jwt(op)))
        assert me.status_code == 200 and me.json()["is_admin"] is False
        # cleanup grant + created user
        client.delete(f"/api/v1/access-grants/{gid.json()['id']}", headers=_h(_jwt(admin)))
        client.delete(f"/api/v1/users/{cu.json()['username']}", headers=_h(_jwt(admin)))
    await db_session.commit()


async def test_create_grant_validation(db_session):
    admin = await _user(db_session, "admin")
    with TestClient(create_app()) as client:
        r = client.post("/api/v1/access-grants", json={"subject_kind": "user", "subject_ref": "x", "scope": "host"}, headers=_h(_jwt(admin)))
        assert r.status_code == 422  # scope=host requires agent_id
    await db_session.commit()
