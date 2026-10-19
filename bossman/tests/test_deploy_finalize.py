"""Finalizing a deployment (services/finalize.py) and the deploy wizard's REST surface (api/provision_deploy.py).

Pinned: an unknown runbook or a role is refused before anything is created; an AI caller may not let the
finalization APPLY without YOLO mode (the run_runbook gate) while a person in the wizard may; a waiting finalization
starts exactly once when the host reports and ends done/failed with a summary; the wizard's catalog and dry run come
from the same code as the MCP tools.
"""
from __future__ import annotations

import asyncio
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, select, text

from bossman.db.models import Agent, DeployFinalization, Runbook
from bossman.services import finalize

TAG = uuid.uuid4().hex[:6]
RB = f"kt-finalize-{TAG}"


@pytest.fixture
async def stored(db_session):
    from bossman.db.models import DEFAULT_TENANT_ID

    db_session.add(Runbook(tenant_id=DEFAULT_TENANT_ID, name=RB, kind="runbook", doc={
        "kind": "runbook", "name": RB, "steps": [{"name": "motd", "module": "copy",
                                                   "args": {"dest": "/etc/motd", "content": "hi"}}]}))
    db_session.add(Runbook(tenant_id=DEFAULT_TENANT_ID, name=RB + "-role", kind="role", doc={
        "kind": "role", "name": RB + "-role", "steps": [{"name": "x", "module": "copy", "args": {"dest": "/x", "content": ""}}]}))
    agent = Agent(name=f"kt-fin-{TAG}", token="t", address="10.251.9.5:18051", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.commit()
    yield agent
    from bossman.api.agents import purge_agent_rows

    await db_session.execute(delete(DeployFinalization).where(DeployFinalization.hostname.like(f"kt-fin-{TAG}%")))
    await db_session.execute(text("SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0"))
    await purge_agent_rows(db_session, agent.id)
    await db_session.execute(delete(Agent).where(Agent.id == agent.id))
    await db_session.execute(delete(Runbook).where(Runbook.name.like(f"{RB}%")))
    await db_session.commit()


async def test_check_runbook_refuses_missing_and_roles(db_session, stored):
    with pytest.raises(finalize.FinalizeError, match="no runbook"):
        await finalize.check_runbook(db_session, RB + "-nope")
    with pytest.raises(finalize.FinalizeError, match="is a role"):
        await finalize.check_runbook(db_session, RB + "-role")
    assert (await finalize.check_runbook(db_session, RB)).name == RB


async def test_waiting_starts_once_when_the_host_reports(db_session, stored, monkeypatch):
    from bossman.services import runbook_exec

    calls = []

    async def fake_exec(session, agent, doc, *, settings, client, request_vars, dry_run, requested_by, commit):
        calls.append({"host": agent.name, "dry_run": dry_run, "vars": request_vars})
        return None, {"ok": True, "changed": True, "aborted": False, "check_mode": dry_run,
                      "steps": [{"name": "motd", "module": "copy", "status": "changed", "changed": True}]}

    monkeypatch.setattr(runbook_exec, "execute_runbook", fake_exec)
    row = await finalize.arm(db_session, stored, runbook=RB, variables={"greeting": "hi"}, apply=True,
                             requested_by="tester")
    from sqlalchemy.ext.asyncio import async_sessionmaker

    factory = async_sessionmaker(db_session.bind, expire_on_commit=False)
    assert await finalize.kick(db_session, session_factory=factory, settings=None, client_factory=lambda a, s: None) == []
    stored.last_seen_at = datetime.now(timezone.utc) + timedelta(seconds=1)
    await db_session.commit()
    started = await finalize.kick(db_session, session_factory=factory, settings=None, client_factory=lambda a, s: None)
    assert started == [stored.name]
    assert await finalize.kick(db_session, session_factory=factory, settings=None, client_factory=lambda a, s: None) == []
    for _ in range(50):
        await asyncio.sleep(0.05)
        await db_session.refresh(row)
        if row.status in ("done", "failed"):
            break
    assert row.status == "done" and row.result["changed"] is True and row.result["steps"][0]["status"] == "changed"
    assert calls == [{"host": stored.name, "dry_run": False, "vars": {"greeting": "hi"}}]
    st = await finalize.status(db_session, stored.name)
    assert st["status"] == "done" and st["finished_at"]


async def test_wizard_rest_catalog_and_plan_gates(db_session, stored, monkeypatch):
    from bossman.main import create_app
    from bossman.services import vm_provision as vp

    class _Hv:
        async def placement(self):
            return {"kind": "proxmox", "nodes": [{"node": "pve1", "storages": [{"name": "local"}], "bridges": [{"name": "vmbr0"}]}]}

    monkeypatch.setattr(vp, "client_for", lambda h: _Hv())
    from bossman.db.models import VmHost

    vmh = VmHost(name=f"hv-{TAG}", kind="proxmox", host="pve.example", username="root@pam", secret="unused")
    db_session.add(vmh)
    await db_session.commit()
    try:
        with TestClient(create_app()) as client:
            login = client.post("/api/v1/auth/login", json={"username": "admin", "password": "admin123"})
            headers = {"Authorization": "Bearer " + login.json()["access_token"]} if login.status_code == 200 else {}
            if not headers:
                pytest.skip("no admin login on this database")
            cat = client.get("/api/v1/provisioning/catalog", headers=headers).json()
            assert {i["install"] for i in cat["installs"]} == {"fedora", "alma", "debian", "ubuntu"}
            assert any(r["name"] == RB for r in cat["runbooks"])
            assert any(h["name"] == f"hv-{TAG}" and h["placement"]["nodes"][0]["node"] == "pve1" for h in cat["vm_hosts"])

        # The plan's gates, called as deploy() does: a person may apply the finalization, an AI only with YOLO.
        from bossman.services.compiler import is_yolo_mode

        yolo = await is_yolo_mode(db_session)
        for ai in (False, True):
            pre = await vp.plan(db_session, None, lambda a, s: None, vm_host=vmh, node="pve1", storage="local",
                                bridge="vmbr0", image=None, hostname=f"kt-fin-{TAG}-new", network=None,
                                finalize={"runbook": RB, "apply": True}, ai=ai)
            checks = {c["check"]: c for c in pre["checks"]}
            assert checks["finalization runbook"]["ok"]
            if ai:
                assert checks["finalization may apply"]["ok"] is yolo
            else:
                assert "finalization may apply" not in checks
        pre = await vp.plan(db_session, None, lambda a, s: None, vm_host=vmh, node="pve1", storage="local",
                            bridge="vmbr0", image=None, hostname=f"kt-fin-{TAG}-new", network=None,
                            finalize={"runbook": RB + "-nope"}, ai=False)
        assert not {c["check"]: c for c in pre["checks"]}["finalization runbook"]["ok"]
    finally:
        await db_session.execute(delete(VmHost).where(VmHost.id == vmh.id))
        await db_session.commit()
