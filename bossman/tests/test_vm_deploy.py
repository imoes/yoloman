"""VM deployment over MCP: check_ip / suggest_free_ips / deploy_vm / deployment_status.

DB-backed with a fake agent (the live probe) and a fake hypervisor. Pinned: an address is free only when the
live probe ran and saw nothing and no record holds it — Bossman's own planned address and an ARP answer each
make it in_use, a subnet without a probe agent makes it unknown; deploy_vm's dry run creates nothing and lists
every check; a failing check refuses the real run before a VM exists; a passing run creates the VM, the planned
host and the restore job, and deployment_status reports them.
"""
from __future__ import annotations

import uuid

import pytest
from sqlalchemy import delete, select

from bossman.db.models import Agent, DiskImage, RestoreJob
from bossman.mcp.server import build_mcp_server
from bossman.services import vm_provision
from bossman.services.catalog import CatalogCache
from tests.test_mcp_server import FakeEmbeddingClient, _call, _settings, session_factory  # noqa: F401

NET = "10.250.%d" % (uuid.uuid4().int % 200 + 20)


class ProbeAgent:
    """Answers the ip_check probe: {address: (ping, mac)}. Records which agent was asked."""

    def __init__(self, seen: dict[str, tuple[bool, str | None]]):
        self.seen = seen
        self.calls = 0
        self.asked: list[str] = []

    def bind(self, agent):
        self.asked.append(agent.name)
        return self

    async def call_tool(self, name, body):
        assert name == "command"
        self.calls += 1
        lines = []
        for a in body["argv"][4:]:
            ping, mac = self.seen.get(a, (False, None))
            neigh = f"{a} dev ens19 lladdr {mac} REACHABLE" if mac else f"{a} dev ens19 FAILED"
            lines.append(f"{a}|{1 if ping else 0}|{neigh}")
        return {"changed": True, "data": {"stdout": "\n".join(lines) + "\n"}}


class FakeHypervisor:
    def __init__(self):
        self.created = []

    async def placement(self):
        return {"kind": "proxmox", "nodes": [{"node": "pve1", "storages": [{"name": "local-lvm"}],
                                              "bridges": [{"name": "vmbr0"}]}]}

    async def create_vm(self, node, name, **kw):
        self.created.append((node, name, kw))
        return {"vmid": "9101", "mac": "BC:24:11:AA:BB:CC"}

    async def vm_power(self, vmid, action, node=None):
        self.powered = getattr(self, "powered", []) + [(str(vmid), action)]
        return {"vmid": str(vmid), "action": action, "ok": True}

    async def vm_delete(self, vmid, node=None):
        self.created = [c for c in self.created if c[1] != vmid]
        self.deleted = getattr(self, "deleted", []) + [str(vmid)]
        return {"vmid": str(vmid), "node": node, "deleted": True}


@pytest.fixture
async def world(db_session, monkeypatch):
    from datetime import datetime, timezone

    prober = Agent(name=f"probe-{NET}", address=f"{NET}.5:8010", token="t", mode="standalone",
                   enrollment_state="enrolled", facts={"nics": [{"name": "ens19", "ipv4": [f"{NET}.5"]}]},
                   last_seen_at=datetime.now(timezone.utc))
    # Enrolled in the same subnet but never reported (a host still installing): must never be the probe.
    silent = Agent(name=f"silent-{NET}", address=f"{NET}.6:8010", token="t", mode="standalone",
                   enrollment_state="enrolled")
    planned = Agent(name=f"planned-{NET}", address=None, token="t", mode="standalone", enrollment_state="planned",
                    agent_metadata={"provision_network": {"mode": "static", "address": f"{NET}.20/24"}})
    img = DiskImage(name=f"img-{NET}", status="ready")
    db_session.add_all([prober, silent, planned, img])
    await db_session.commit()
    hv = FakeHypervisor()
    monkeypatch.setattr(vm_provision, "client_for", lambda vm_host: hv)
    yield {"prober": prober, "planned": planned, "image": img, "hv": hv}
    from sqlalchemy import text as _text

    from bossman.api.agents import purge_agent_rows
    from bossman.db.models import DeployFinalization, Downtime, NetinstallJob

    await db_session.execute(delete(RestoreJob).where(RestoreJob.target_hostname.like(f"%{NET}%")))
    await db_session.execute(delete(NetinstallJob).where(NetinstallJob.hostname.like(f"%{NET}%")))
    ids = (await db_session.scalars(select(Agent.id).where(Agent.name.like(f"%{NET}%")))).all()
    # Deleting an agent cascades into compressed hypertables; the API's delete route lifts the same limit.
    await db_session.execute(_text("SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0"))
    for agent_id in ids:
        await purge_agent_rows(db_session, agent_id)
    await db_session.execute(delete(DeployFinalization).where(DeployFinalization.agent_id.in_(ids)))
    await db_session.execute(delete(Downtime).where(Downtime.agent_id.in_(ids)))
    await db_session.execute(delete(Agent).where(Agent.id.in_(ids)))
    await db_session.execute(delete(DiskImage).where(DiskImage.name == f"img-{NET}"))
    from bossman.db.models import VmHost
    await db_session.execute(delete(VmHost).where(VmHost.name == f"hv-{NET}"))
    await db_session.commit()


def _mcp(session_factory, tmp_path, agent):
    # netboot_secret: the env fallback that switches netboot on when the DB holds no secret (the shared DB's
    # real toggle is never flipped by a test).
    return build_mcp_server(session_factory, _settings(str(tmp_path), netboot_secret="test-netboot"), CatalogCache(str(tmp_path)),
                            FakeEmbeddingClient(), client_factory=lambda a, s: agent.bind(a) if hasattr(agent, "bind") else agent)


async def test_check_ip_needs_every_source(world, session_factory, tmp_path):
    probe = ProbeAgent({f"{NET}.30": (False, "bc:24:11:00:00:30")})
    mcp = _mcp(session_factory, tmp_path, probe)
    got = {r["address"]: r for r in await _call(mcp, "check_ip", {"addresses": [f"{NET}.20", f"{NET}.30", f"{NET}.40"]})}
    assert got[f"{NET}.20"]["verdict"] == "in_use" and f"planned-{NET}" in got[f"{NET}.20"]["reason"]
    assert got[f"{NET}.30"]["verdict"] == "in_use" and got[f"{NET}.30"]["sources"]["live"]["mac"] == "bc:24:11:00:00:30"
    assert got[f"{NET}.40"]["verdict"] == "free"
    assert got[f"{NET}.40"]["sources"]["netbox"].startswith("not configured")
    assert probe.calls == 1, "one probe call for the whole batch"
    assert probe.asked == [f"probe-{NET}"], "an agent that never reported must not be the probe"

    other = await _call(mcp, "check_ip", {"addresses": ["10.249.1.7"]})
    assert other[0]["verdict"] == "unknown" and "no enrolled agent" in other[0]["reason"]


async def test_deploy_vm_dry_run_refusal_and_run(world, db_session, session_factory, tmp_path):
    from bossman.db.models import VmHost

    # The secret is never decrypted: client_for is replaced by the fake hypervisor.
    db_session.add(VmHost(name=f"hv-{NET}", kind="proxmox", host="pve.example", username="root@pam", secret="unused"))
    await db_session.commit()
    mcp = _mcp(session_factory, tmp_path, ProbeAgent({}))
    base = {"vm_host": f"hv-{NET}", "node": "pve1", "storage": "local-lvm", "bridge": "vmbr0",
            "image": f"img-{NET}", "gateway": f"{NET}.254", "dns": ["203.0.113.115"], "vlan": 1028}

    taken = await _call(mcp, "deploy_vm", {**base, "name": f"vm-{NET}", "address": f"{NET}.20/24", "dry_run": False})
    assert taken["would_deploy"] is False and world["hv"].created == []
    assert any(c["check"] == "address free" and not c["ok"] for c in taken["checks"])

    plan = await _call(mcp, "deploy_vm", {**base, "name": f"vm-{NET}", "address": f"{NET}.41/24", "storage": "nope"})
    assert plan["dry_run"] is True and plan["would_deploy"] is False and world["hv"].created == []
    assert [c["check"] for c in plan["checks"] if not c["ok"]] == ["storage exists on the node"]

    done = await _call(mcp, "deploy_vm", {**base, "name": f"vm-{NET}", "address": f"{NET}.41/24", "dry_run": False})
    assert done["vmid"] == "9101" and done["mac"] == "bc:24:11:aa:bb:cc"
    assert world["hv"].created[0][2]["vlan"] == 1028
    st = await _call(mcp, "deployment_status", {"hostname": f"vm-{NET}"})
    assert st["restore"]["status"] == "pending" and st["host"]["enrollment_state"] == "planned"
    assert "waited_s" not in st
    # wait_s long-polls: nothing changes here, so it answers after the wait with changed=false.
    waited = await _call(mcp, "deployment_status", {"hostname": f"vm-{NET}", "wait_s": 1})
    assert waited["changed"] is False and waited["waited_s"] >= 1 and waited["restore"]["status"] == "pending"
    row = await db_session.scalar(select(Agent).where(Agent.name == f"vm-{NET}"))
    await db_session.refresh(row)
    assert row.agent_metadata["provision_network"]["address"] == f"{NET}.41/24"

    with pytest.raises(Exception, match="gateway"):
        await _call(mcp, "deploy_vm", {**base, "name": "x", "address": f"{NET}.42/24", "gateway": "10.1.1.1"})


async def test_deploy_vm_install_fedora_arms_a_netinstall(world, db_session, session_factory, tmp_path, monkeypatch):
    from bossman.db.models import Downtime, NetinstallJob, VmHost
    from bossman.services import netinstall

    async def fake_release(settings, distro, release):
        return {"distro": distro, "release": release or "44", "label": f"Fedora {release or '44'}", "family": "redhat",
                **netinstall.Fedora()._urls(release or "44")}

    monkeypatch.setattr(netinstall, "resolve_release", fake_release)
    missing: list[str] = []

    async def fake_missing(settings, install, packages):
        pkgs = list(netinstall.DRIVERS["fedora"].default_packages if packages is None else packages)
        return pkgs, [p for p in pkgs if p in missing]

    monkeypatch.setattr(netinstall, "missing_packages", fake_missing)
    db_session.add(VmHost(name=f"hv-{NET}", kind="proxmox", host="pve.example", username="root@pam", secret="unused"))
    await db_session.commit()
    settings = _settings(str(tmp_path), netinstall_http_base="http://192.0.2.130:8080", netboot_secret="test-netboot",
                         client_cert_path=str(tmp_path / "c.crt"), client_key_path=str(tmp_path / "c.key"))
    mcp = build_mcp_server(session_factory, settings, CatalogCache(str(tmp_path)), FakeEmbeddingClient(),
                           client_factory=lambda a, s: ProbeAgent({}))
    base = {"vm_host": f"hv-{NET}", "node": "pve1", "storage": "local-lvm", "bridge": "vmbr0", "vlan": 1028,
            "gateway": f"{NET}.254", "dns": ["203.0.113.115"], "name": f"fed-{NET}", "address": f"{NET}.60/24"}
    try:
        from mcp.server.fastmcp.exceptions import ToolError
        with pytest.raises(ToolError, match="exactly one of image"):
            await _call(mcp, "deploy_vm", {**base, "image": f"img-{NET}", "install": "fedora"})

        missing.append("scx-scheds")
        refused = await _call(mcp, "deploy_vm", {**base, "install": "fedora-44", "packages": ["scx-scheds", "fio"], "dry_run": False})
        assert refused["would_deploy"] is False and world["hv"].created == []
        assert any(c["check"] == "packages available" and "scx-scheds" in c["detail"] for c in refused["checks"])

        plan = await _call(mcp, "deploy_vm", {**base, "install": "fedora-44"})
        assert plan["would_deploy"] is True and plan["install"]["release"] == "44"
        assert any(c["check"] == "installer available" for c in plan["checks"])

        done = await _call(mcp, "deploy_vm", {**base, "install": "fedora-44", "memory_mb": 4096, "dry_run": False})
        assert done["mac"] == "bc:24:11:aa:bb:cc" and done["install"]["status"] == "pending"
        assert "scx_rusty" in done["install"]["packages"]
        st = await _call(mcp, "deployment_status", {"hostname": f"fed-{NET}"})
        assert st["install"]["status"] == "pending" and st["install"]["mac"] == "bc:24:11:aa:bb:cc"
        # Created stopped; the pxe container's readiness report starts it — once.
        assert world["hv"].created[-1][2]["start"] is False
        async with session_factory() as s2:
            first = await netinstall.mark_ready(s2, "bc:24:11:aa:bb:cc")
            again = await netinstall.mark_ready(s2, "bc:24:11:aa:bb:cc")
        assert first["action"] == "started" and again["action"] == "none" and world["hv"].powered == [("9101", "start")]
        st = await _call(mcp, "deployment_status", {"hostname": f"fed-{NET}"})
        assert st["install"]["status"] == "installing"

        from mcp.server.fastmcp.exceptions import ToolError as _TE
        with pytest.raises(_TE, match="was not created by Bossman"):
            await _call(mcp, "vm_delete", {"vm_host": f"hv-{NET}", "vmid": "4242"})
        # A host that has reported is kept unless remove_host=true (the VM is gone, so is the host).
        from datetime import datetime, timezone

        async with session_factory() as s3:
            row = await s3.scalar(select(Agent).where(Agent.name == f"fed-{NET}"))
            row.last_seen_at = datetime.now(timezone.utc)
            await s3.commit()
        kept = await _call(mcp, "vm_delete", {"vm_host": f"hv-{NET}", "vmid": "9101"})
        assert kept["deleted"] and kept["agent"].startswith("kept") and "remove_host=true" in kept["agent"]
        gone = await _call(mcp, "vm_delete", {"vm_host": f"hv-{NET}", "vmid": "9101", "remove_host": True})
        assert world["hv"].deleted == ["9101", "9101"] and gone["agent"].startswith("removed") and "remove_host" in gone["agent"]
        st = await _call(mcp, "deployment_status", {"hostname": f"fed-{NET}"})
        assert st["install"]["status"] == "vm_deleted" and "the deployment was " in st["install"]["error"] and "host" not in st
    finally:
        await db_session.execute(delete(NetinstallJob).where(NetinstallJob.hostname == f"fed-{NET}"))
        ids = (await db_session.scalars(select(Agent.id).where(Agent.name == f"fed-{NET}"))).all()
        await db_session.execute(delete(Downtime).where(Downtime.agent_id.in_(ids)))
        await db_session.commit()


async def test_deploy_bare_metal_own_sizing_and_roles(world, db_session, session_factory, tmp_path):
    # One deployment path for what the old provisioning wizard did by hand: bare metal by MAC, the deployment's
    # own volume sizing (the image's default stays), and roles actually bound (they used to be stored, never bound).
    from uuid import uuid4

    from bossman.db.models import (DEFAULT_TENANT_ID, OrchestrationPlan, OrchestrationPlanLink,
                                   OrchestrationPlanVersion)

    role = OrchestrationPlan(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=f"role-{NET}", display_name="R",
                             plan_type="role", current_version=1)
    db_session.add(role)
    db_session.add(OrchestrationPlanVersion(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=role.id, version=1))
    await db_session.commit()
    try:
        mcp = _mcp(session_factory, tmp_path, ProbeAgent({}))
        base = {"target": "bare_metal", "name": f"bm-{NET}", "address": f"{NET}.42/24", "gateway": f"{NET}.254",
                "dns": ["203.0.113.115"]}
        # A network install boots a per-MAC entry: without the MAC it is refused, with the reason.
        async with session_factory() as s0:
            nomac = await vm_provision.plan(s0, _settings(str(tmp_path)), lambda a, s: None, vm_host=None, node="",
                                            storage="", bridge="", image=None, hostname=f"bm-{NET}", network=None,
                                            install={"distro": "debian", "release": "13", "kernel": "linux"})
        assert not {c["check"]: c for c in nomac["checks"]}["machine identified by MAC"]["ok"]
        # Unknown role and bad sizing are named in the dry run.
        bad = await _call(mcp, "deploy_vm", {**base, "image": f"img-{NET}", "mac": "aa:bb:cc:00:42:01",
                                             "roles": ["no-such-role"], "grow_policy": {"/nope": 10}})
        failed = {c["check"]: c for c in bad["checks"] if not c["ok"]}
        assert "role no-such-role" in failed and "unknown keys" in failed["volume sizing"]["detail"]
        assert world["hv"].created == []

        done = await _call(mcp, "deploy_vm", {**base, "image": f"img-{NET}", "mac": "AA-BB-CC-00-42-01",
                                              "roles": [f"role-{NET}"], "grow_policy": {"root": 60, "var": 40},
                                              "dry_run": False})
        assert done["mac"] == "aa:bb:cc:00:42:01" and world["hv"].created == [], "bare metal creates no VM"
        assert done["roles"][0]["role"] == f"role-{NET}" and done["roles"][0]["status"] in ("active", "pending_approval")
        job = await db_session.scalar(select(RestoreJob).where(RestoreJob.target_hostname == f"bm-{NET}"))
        await db_session.refresh(job)
        assert job.grow_mode == "percent" and job.grow_policy == {"root": 60, "var": 40}
        img = await db_session.scalar(select(DiskImage).where(DiskImage.name == f"img-{NET}"))
        await db_session.refresh(img)
        assert img.grow_policy == {}, "the image's own default is not touched by one deployment"
        links = (await db_session.scalars(select(OrchestrationPlanLink).where(OrchestrationPlanLink.plan_id == role.id))).all()
        assert len(links) == 1 and str(links[0].agent_id) == done["host_id"]
    finally:
        await db_session.execute(delete(OrchestrationPlanLink).where(OrchestrationPlanLink.plan_id == role.id))
        await db_session.execute(delete(OrchestrationPlanVersion).where(OrchestrationPlanVersion.plan_id == role.id))
        await db_session.execute(delete(OrchestrationPlan).where(OrchestrationPlan.id == role.id))
        await db_session.commit()
