"""End-to-end tests for POST /api/v1/enroll/deploy (Block N-enroll). The
route is always mounted; when deploy isn't configured it must return a
helpful 400, not a 404. The happy path (real SSH) is verified live.
"""

from fastapi.testclient import TestClient

from bossman.main import create_app
from bossman.services.auth import new_api_token


async def _make_api_token(db_session):
    row, raw = new_api_token("deploy-caller")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, raw


async def test_deploy_requires_auth():
    with TestClient(create_app()) as client:
        resp = client.post("/api/v1/enroll/deploy", json={"host": "h.example.com"})
    assert resp.status_code == 401


async def test_deploy_400_when_not_configured(db_session, monkeypatch):
    monkeypatch.delenv("BOSSMAN_DEPLOY_SSH_USER", raising=False)
    monkeypatch.delenv("BOSSMAN_AGENT_DEB_PATH", raising=False)
    api_token, raw = await _make_api_token(db_session)

    with TestClient(create_app()) as client:
        resp = client.post(
            "/api/v1/enroll/deploy",
            json={"host": "h.example.com"},
            headers={"Authorization": f"Bearer {raw}"},
        )

    assert resp.status_code == 400
    assert "not configured" in resp.json()["detail"]

    await db_session.delete(api_token)
    await db_session.commit()


# ── The deployment EDGES (docs/ui-workspaces.md): "what runs on this host" / "where is this deployed" ──


async def _deployment(db_session, *, target_ref: str, agent_id: str, name: str = "h"):
    """One recorded multi-host deployment whose per-host results name `agent_id`."""
    from bossman.db.models import DEFAULT_TENANT_ID, DeploymentRun

    row = DeploymentRun(
        tenant_id=DEFAULT_TENANT_ID, kind="runbook", target_ref=target_ref, dry_run=False,
        status="ok", total_hosts=1, ok_hosts=1, failed_hosts=0, unknown_hostnames=[],
        results=[{"agent_id": agent_id, "agent_name": name, "status": "succeeded", "changed": True}],
        requested_by="test",
    )
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row


async def test_deployments_filter_by_host_and_by_artefact(db_session):
    """The two navigable edges the UI was missing: a host's deployments, and an artefact's deployments.
    Without these the operator can only read a flat audit trail — never 'where is this role deployed'."""
    from uuid import uuid4

    from bossman.db.models import DeploymentRun

    api_token, raw = await _make_api_token(db_session)
    a, b = str(uuid4()), str(uuid4())
    d1 = await _deployment(db_session, target_ref="install-nginx", agent_id=a, name="web1")
    d2 = await _deployment(db_session, target_ref="install-redis", agent_id=b, name="cache1")
    headers = {"Authorization": f"Bearer {raw}"}

    with TestClient(create_app()) as client:
        # host edge — only the deployment whose results include that host
        got = client.get(f"/api/v1/deployments?agent_id={a}", headers=headers)
        assert got.status_code == 200, got.text
        ids = [d["id"] for d in got.json()["deployments"]]
        assert str(d1.id) in ids and str(d2.id) not in ids

        # artefact edge — only the deployments of that artefact
        got = client.get("/api/v1/deployments?target_ref=install-redis", headers=headers)
        ids = [d["id"] for d in got.json()["deployments"]]
        assert str(d2.id) in ids and str(d1.id) not in ids

        # both filters together must intersect, not union
        got = client.get(f"/api/v1/deployments?agent_id={a}&target_ref=install-redis", headers=headers)
        assert got.json()["deployments"] == []

        # unfiltered still lists everything (the audit trail is unchanged)
        got = client.get("/api/v1/deployments", headers=headers)
        ids = [d["id"] for d in got.json()["deployments"]]
        assert str(d1.id) in ids and str(d2.id) in ids

    for row in (d1, d2):
        await db_session.delete(row)
    await db_session.delete(api_token)
    await db_session.commit()
