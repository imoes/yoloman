"""Patch rings (plan B13): a Windows-update rollout in waves — DB-backed.

The rules: the generated runbook has one windows_update step with the chosen args; a patch ring keeps only Windows
hosts and lists the rest with a reason; the same patch set reuses one runbook; nothing installs on creation.
"""

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from bossman.db.models import Rollout, Runbook
from bossman.main import create_app
from bossman.services import nt_runbook, patch_ring
from tests.naming import owned_name
from tests.test_management_api import _headers, _make_agent, _make_api_token


def owned_group():
    return owned_name("patchgrp")


async def test_the_runbook_has_one_windows_update_step_and_is_reused_by_signature(db_session):
    n1 = await patch_ring.ensure_patch_runbook(db_session, accept=["KB5062553"], reboot="if_required")
    n2 = await patch_ring.ensure_patch_runbook(db_session, accept=["KB5062553"], reboot="if_required")
    assert n1 == n2 and "KB5062553" in n1
    rows = (await db_session.scalars(select(Runbook).where(Runbook.name == n1))).all()
    assert len(rows) == 1                                   # reused, not duplicated
    doc = nt_runbook.parse_data(rows[0].doc)
    step = doc.steps[0]
    assert step.module == "windows_update"
    assert step.args["accept_list"] == ["KB5062553"] and step.args["reboot"] == "if_required"
    assert step.args["category_names"] == patch_ring.DEFAULT_CATEGORIES
    await db_session.delete(rows[0]); await db_session.commit()


async def test_windows_only_keeps_windows_and_names_the_rest(db_session):
    win = await _make_agent(db_session, facts={"os_family": "windows"})
    lin = await _make_agent(db_session, facts={"os_family": "debian"})
    kept, dropped = await patch_ring.windows_only(db_session, [str(win.id), str(lin.id), str(uuid.uuid4())])
    assert kept == [str(win.id)]
    reasons = {d.get("host") or d["agent_id"]: d["reason"] for d in dropped}
    assert any("not a Windows host" in r for r in reasons.values())
    assert any("no such host" in r for r in reasons.values())
    for a in (win, lin):
        await db_session.delete(a)
    await db_session.commit()


async def test_create_patch_ring_builds_windows_only_waves_and_installs_nothing(db_session):
    # a one-host group of a Windows + a Linux host: deterministic regardless of what else is in the shared DB
    from bossman.db.models import HostGroup, HostGroupMember
    win = await _make_agent(db_session, facts={"os_family": "windows"})
    lin = await _make_agent(db_session, facts={"os_family": "debian"})
    g = HostGroup(name=owned_group(), tenant_id=win.tenant_id)
    db_session.add(g); await db_session.flush()
    db_session.add_all([HostGroupMember(host_group_id=g.id, agent_id=win.id, tenant_id=win.tenant_id),
                        HostGroupMember(host_group_id=g.id, agent_id=lin.id, tenant_id=win.tenant_id)])
    await db_session.commit()
    token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.post("/api/v1/patch-rings", headers=_headers(raw), json={
            "name": "wintest ring", "scope_type": "group", "host_group_id": str(g.id),
            "accept_list": ["KB5062553"], "reboot": "never"})
    assert resp.status_code == 200, resp.text
    out = resp.json()
    assert out["windows_hosts"] == 1
    assert any(str(lin.id) == d["agent_id"] for d in out["skipped"])
    assert out["rollout"]["status"] == "pending" and out["rollout"]["dry_run"] is True
    all_wave_ids = [a for w in out["rollout"]["waves"] for a in w["agent_ids"]]
    assert all_wave_ids == [str(win.id)]                    # the Linux host is not in any wave
    r = await db_session.get(Rollout, uuid.UUID(out["rollout"]["id"]))
    assert r.status == "pending"                            # nothing started
    await db_session.delete(r)
    rb = await db_session.scalar(select(Runbook).where(Runbook.name == out["runbook_name"]))
    if rb: await db_session.delete(rb)
    for m in (await db_session.scalars(select(HostGroupMember).where(HostGroupMember.host_group_id == g.id))).all():
        await db_session.delete(m)
    await db_session.delete(g)
    for a in (win, lin, token):
        await db_session.delete(a)
    await db_session.commit()


async def test_a_scope_without_windows_hosts_is_refused(db_session):
    lin = await _make_agent(db_session, facts={"os_family": "debian"})
    token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.post("/api/v1/patch-rings", headers=_headers(raw), json={
            "name": "no-win", "scope_type": "host", "agent_id": str(lin.id)})
    assert resp.status_code == 422 and "no Windows hosts" in resp.json()["detail"]
    for a in (lin, token):
        await db_session.delete(a)
    await db_session.commit()
