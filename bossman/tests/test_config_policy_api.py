"""Characterization tests for config-policy authoring (POST /api/v1/config-policies).

Pins the behavior the Policy console relies on BEFORE it is extracted into a shared service (so the MCP tool can
author the same way): a real save persists the policy and merges values; a dry-run previews without persisting; an
unlinked policy (no scope) is created inert. The OUs here have no member agents, so the convergence step is a no-op and
no agent client is touched — exactly the authoring behavior under test. Real HTTP + real Postgres (db_session fixture).
"""

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

from bossman.main import create_app
from bossman.services.auth import new_api_token
from tests.naming import owned_name, run_suffix


async def _token(db_session):
    row, raw = new_api_token(owned_name("cp-test"))
    db_session.add(row)
    await db_session.commit()
    return raw


def _h(raw):
    return {"Authorization": f"Bearer {raw}"}


async def _cleanup(db_session, like):
    await db_session.execute(text("DELETE FROM config_policies WHERE path LIKE :p"), {"p": like})
    await db_session.execute(text("DELETE FROM ou_nodes WHERE name LIKE :p"), {"p": like})
    await db_session.commit()


async def test_real_save_persists_and_merges_values(db_session):
    raw = await _token(db_session)
    sfx = run_suffix()
    path = f"/etc/cp-{sfx}.conf"
    with TestClient(create_app()) as client:
        ou = client.post("/api/v1/ou", json={"name": f"cp-{sfx}"}, headers=_h(raw)).json()
        r1 = client.post("/api/v1/config-policies", headers=_h(raw), json={
            "scope_ou_id": ou["id"], "path": path, "format": "keyvalue", "values": {"A": "1"}, "dry_run": False})
        assert r1.status_code == 200, r1.text
        body = r1.json()
        assert body["scope"] == "ou" and body["dry_run"] is False
        assert body["applied_hosts"] == [] and body["skipped_hosts"] == []   # no member agents → converge is a no-op

        # Persisted, and a second save MERGES rather than replaces (keyvalue).
        client.post("/api/v1/config-policies", headers=_h(raw), json={
            "scope_ou_id": ou["id"], "path": path, "format": "keyvalue", "values": {"B": "2"}, "dry_run": False})
        rows = client.get("/api/v1/config-policies", headers=_h(raw), params={"scope_ou_id": ou["id"]}).json()
        mine = [c for c in rows if c["path"] == path]
        assert len(mine) == 1
        assert mine[0]["values"] == {"A": "1", "B": "2"}                      # merged, not replaced
    await _cleanup(db_session, f"%cp-{sfx}%")


async def test_dry_run_does_not_persist(db_session):
    raw = await _token(db_session)
    sfx = run_suffix()
    path = f"/etc/cp-{sfx}.conf"
    with TestClient(create_app()) as client:
        ou = client.post("/api/v1/ou", json={"name": f"cp-{sfx}"}, headers=_h(raw)).json()
        r = client.post("/api/v1/config-policies", headers=_h(raw), json={
            "scope_ou_id": ou["id"], "path": path, "format": "keyvalue", "values": {"A": "1"}, "dry_run": True})
        assert r.status_code == 200 and r.json()["dry_run"] is True
        rows = client.get("/api/v1/config-policies", headers=_h(raw), params={"scope_ou_id": ou["id"]}).json()
        assert [c for c in rows if c["path"] == path] == []                  # preview only — nothing stored
    await _cleanup(db_session, f"%cp-{sfx}%")


async def test_unlinked_policy_is_created_inert(db_session):
    raw = await _token(db_session)
    sfx = run_suffix()
    path = f"/etc/cp-{sfx}.conf"
    with TestClient(create_app()) as client:
        r = client.post("/api/v1/config-policies", headers=_h(raw), json={
            "path": path, "format": "keyvalue", "values": {"A": "1"}, "dry_run": False})
        assert r.status_code == 200
        body = r.json()
        assert body["scope"] is None and body["applied_hosts"] == []         # inert: no scope, nothing to converge
        unlinked = client.get("/api/v1/config-policies", headers=_h(raw), params={"unlinked": True}).json()
        assert any(c["path"] == path for c in unlinked)
    await _cleanup(db_session, f"%cp-{sfx}%")


# ── the MCP tool set_config_policy (shares author_config_policy with the REST route) ──
from bossman.mcp.server import build_mcp_server  # noqa: E402
from bossman.services.catalog import CatalogCache  # noqa: E402
from mcp.server.fastmcp.exceptions import ToolError  # noqa: E402
from tests.test_mcp_server import (  # noqa: E402,F401
    FakeAgentClient, FakeEmbeddingClient, _call, _settings, session_factory)


def _mcp(tmp_path, session_factory):  # noqa: F811
    return build_mcp_server(session_factory, _settings(str(tmp_path)), CatalogCache(str(tmp_path)),
                            FakeEmbeddingClient(), client_factory=lambda a, s: FakeAgentClient())


async def test_set_config_policy_mcp_previews_and_gates_apply(db_session, session_factory, tmp_path):  # noqa: F811
    raw = await _token(db_session)
    sfx = run_suffix()
    path = f"/etc/cp-{sfx}.conf"
    with TestClient(create_app()) as client:
        ou = client.post("/api/v1/ou", json={"name": f"cp-{sfx}"}, headers=_h(raw)).json()
        ou_path = ou["path"]
    mcp = _mcp(tmp_path, session_factory)

    # Preview (dry_run default true): nothing persisted, no member agents to apply to.
    prev = await _call(mcp, "set_config_policy", {"ou": ou_path, "path": path, "values": {"A": "1"}})
    assert prev["dry_run"] is True and prev["scope"] == "ou" and prev["applied_hosts"] == []
    with TestClient(create_app()) as client:
        rows = client.get("/api/v1/config-policies", headers=_h(raw), params={"scope_ou_id": ou["id"]}).json()
        assert [c for c in rows if c["path"] == path] == []                  # preview persisted nothing

    # Apply outside YOLO mode is REFUSED (fleet-wide change is human-owned), with the preview, still nothing stored.
    refused = await _call(mcp, "set_config_policy", {"ou": ou_path, "path": path, "values": {"A": "1"}, "dry_run": False})
    assert refused["applied"] is False and "YOLO" in refused["reason"] and refused["preview"]["scope"] == "ou"
    with TestClient(create_app()) as client:
        rows = client.get("/api/v1/config-policies", headers=_h(raw), params={"scope_ou_id": ou["id"]}).json()
        assert [c for c in rows if c["path"] == path] == []                  # refused apply persisted nothing
    await _cleanup(db_session, f"%cp-{sfx}%")


async def test_set_config_policy_mcp_rejects_bad_scope(db_session, session_factory, tmp_path):  # noqa: F811
    mcp = _mcp(tmp_path, session_factory)
    with pytest.raises(ToolError, match="exactly one scope"):
        await _call(mcp, "set_config_policy", {"path": "/etc/x", "values": {"A": "1"}})   # neither ou nor group
    with pytest.raises(ToolError, match="no OU at path"):
        await _call(mcp, "set_config_policy", {"ou": "/no/such/ou", "path": "/etc/x", "values": {"A": "1"}})
