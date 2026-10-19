"""Block J4 — tests for the Cockpit-like host-management routes
(api/management.py) plus the J4a enable/disable extension of service-control
(api/agents.py). A fake AgentClient is injected via get_client_factory, the
same seam api/processes.py's tests use, so no real agent connection is made.
"""

import uuid
from tests.naming import owned_name

from fastapi.testclient import TestClient

from bossman.api.plans import get_client_factory
from bossman.db.models import Agent
from bossman.main import create_app
from bossman.services.agent_client import AgentClientError
from bossman.services.auth import new_api_token


class CallToolFake:
    """Records call_tool invocations and returns a canned tool envelope."""

    def __init__(self, result=None, raises: bool = False, tools=None):
        self.result = result if result is not None else {"changed": False, "data": []}
        self.raises = raises
        self.tools = tools if tools is not None else [{"name": "systemd", "kind": "module", "writes": True}]
        self.calls: list[tuple[str, dict]] = []

    async def call_tool(self, name, body):
        self.calls.append((name, body))
        if self.raises:
            raise AgentClientError("10.0.0.9:8010: request failed: connection refused")
        return self.result

    async def list_tools(self):
        if self.raises:
            raise AgentClientError("10.0.0.9:8010: request failed: connection refused")
        return self.tools


async def _make_agent(db_session, **overrides) -> Agent:
    fields = {
        "name": owned_name("mgmt-agent"),
        "token": "tok",
        "address": "10.0.0.9:8010",
        "mode": "standalone",
        "enrollment_state": "enrolled",
    }
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _make_api_token(db_session):
    row, raw = new_api_token("mgmt-caller")
    db_session.add(row)
    await db_session.flush()  # the grant references this token by uid — it must exist first
    # These tests exercise the proxy, not the Block-M host ACL — give the token
    # a wildcard grant so require_manage_agent lets it through.
    from bossman.db.models import AccessGrant

    db_session.add(AccessGrant(subject_kind="api_token", subject_ref="mgmt-caller", subject_token_id=row.id, scope="all"))
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _headers(raw):
    return {"Authorization": f"Bearer {raw}"}


def _override(app, fake):
    app.dependency_overrides[get_client_factory] = lambda: (lambda agent, settings: fake)


# ---- J4a: services list ---------------------------------------------------


async def test_services_requires_auth(db_session):
    agent = await _make_agent(db_session)
    with TestClient(create_app()) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/service-units")
    assert resp.status_code == 401
    await db_session.delete(agent)
    await db_session.commit()


async def test_services_proxies_service_facts(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)

    units = [{"unit": "nginx.service", "name": "nginx", "load": "loaded", "active": "active", "sub": "running"}]
    fake = CallToolFake(result={"changed": False, "data": units})
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/service-units", headers=_headers(raw))

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["services"] == units
    assert fake.calls == [("service_facts", {})]

    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_services_unknown_agent_404(db_session):
    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.get(f"/api/v1/agents/{uuid.uuid4()}/service-units", headers=_headers(raw))
    assert resp.status_code == 404
    await db_session.delete(api_token)
    await db_session.commit()


async def test_services_no_address_422(db_session):
    agent = await _make_agent(db_session, address=None)
    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/service-units", headers=_headers(raw))
    assert resp.status_code == 422
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_services_unreachable_502(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    fake = CallToolFake(raises=True)
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/service-units", headers=_headers(raw))
    assert resp.status_code == 502
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


# ---- MCP router: generic tool proxy (REST counterpart) --------------------


async def test_list_agent_tools_proxies_agent(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    tools = [{"name": "service_facts", "kind": "module", "writes": False}, {"name": "systemd", "kind": "module", "writes": True}]
    fake = CallToolFake(tools=tools)
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/tools", headers=_headers(raw))
    assert resp.status_code == 200, resp.text
    assert resp.json()["tools"] == tools
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_call_agent_tool_routes_to_agent(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    fake = CallToolFake(result={"changed": True, "msg": "ok"})
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.post(
            f"/api/v1/agents/{agent.id}/tools/systemd",
            json={"params": {"name": "nginx", "state": "restarted"}},
            headers=_headers(raw),
        )
    assert resp.status_code == 200, resp.text
    assert resp.json()["tool"] == "systemd"
    assert fake.calls == [("systemd", {"name": "nginx", "state": "restarted"})]
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_call_agent_tool_transport_failure_502(db_session):
    """An agent that could not be reached is a gateway fault: 502."""
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    fake = CallToolFake(raises=True)
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.post(
            f"/api/v1/agents/{agent.id}/tools/systemd",
            json={"params": {"name": "nginx", "state": "restarted"}},
            headers=_headers(raw),
        )
    assert resp.status_code == 502
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


class WriteGateFake(CallToolFake):
    """A read-only agent: answers the call with its own 403 and lists the write tool as withheld."""

    REASON = 'tool "package" is disabled (write=false): this agent\'s write gate is closed'

    async def call_tool(self, name, body):
        self.calls.append((name, body))
        raise AgentClientError(f"10.0.0.9:8010: tool {name!r} returned 403: {{\"error\": ...}}",
                               status=403, reason=self.REASON)

    async def tool_listing(self):
        return {"tools": [{"name": "package_facts", "kind": "module", "writes": False}], "write": False,
                "withheld": [{"name": "package", "kind": "module", "writes": True, "reason": self.REASON,
                              "input_schema": {"type": "object", "properties": {"name": {"type": "array"}}}}]}


async def test_call_agent_tool_write_gate_is_relayed_as_403_with_the_agents_reason(db_session):
    """The host's write gate refusing is a decision, not a gateway fault: 403, and the agent's own sentence."""
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    app = create_app()
    _override(app, WriteGateFake())
    with TestClient(app) as client:
        resp = client.post(f"/api/v1/agents/{agent.id}/tools/package",
                           json={"params": {"name": ["redis"]}}, headers=_headers(raw))
    assert resp.status_code == 403, resp.text
    assert "write=false" in resp.json()["detail"]
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_console_tree_reads_the_write_gate_and_names_the_withheld_tool(db_session):
    """A withheld write tool is not "missing": the tree carries its schema with the refusal reason, and the
    gate itself, so the console greys the action out before it is tried."""
    agent = await _make_agent(db_session, facts={"os_family": "debian"})
    api_token, raw = await _make_api_token(db_session)
    app = create_app()
    _override(app, WriteGateFake())
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/mmc", headers=_headers(raw))
    assert resp.status_code == 200, resp.text
    tree = resp.json()
    assert tree["write"] is False
    assert tree["schemas"]["package"]["refused"] == WriteGateFake.REASON
    assert tree["schemas"]["package"]["input_schema"]["properties"]["name"]
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


# ---- J4b: journald logs ---------------------------------------------------


async def test_logs_proxies_journal_with_filters(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)

    entries = [{"timestamp": "2023-11-14T22:13:20Z", "unit": "nginx.service", "priority": "6", "message": "started", "pid": "42", "hostname": "h1"}]
    fake = CallToolFake(result={"changed": False, "data": {"entries": entries, "count": 1}})
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.get(
            f"/api/v1/agents/{agent.id}/logs",
            params={"lines": 50, "unit": "nginx", "priority": "6"},
            headers=_headers(raw),
        )

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["count"] == 1
    assert body["entries"] == entries
    name, params = fake.calls[0]
    assert name == "journal"
    assert params["lines"] == 50 and params["unit"] == "nginx" and params["priority"] == "6"

    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_logs_rejects_out_of_range_lines(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/logs", params={"lines": 99999}, headers=_headers(raw))
    assert resp.status_code == 422
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


# ---- J4c: accounts --------------------------------------------------------


class AccountsFake:
    """getent passwd/group envelopes + records user/group tool calls."""

    def __init__(self):
        self.calls: list[tuple[str, dict]] = []

    async def call_tool(self, name, body):
        self.calls.append((name, body))
        if name == "getent" and body.get("database") == "passwd":
            return {"changed": False, "data": [
                {"name": "root", "fields": ["root", "x", "0", "0", "root", "/root", "/bin/bash"]},
                {"name": "deploy", "fields": ["deploy", "x", "1001", "1001", "Deploy User", "/home/deploy", "/bin/bash"]},
            ]}
        if name == "getent" and body.get("database") == "group":
            return {"changed": False, "data": [
                {"name": "root", "fields": ["root", "x", "0", ""]},
                {"name": "sudo", "fields": ["sudo", "x", "27", "deploy"]},
            ]}
        return {"changed": True, "msg": "ok"}


async def test_accounts_aggregates_passwd_and_group(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    fake = AccountsFake()
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/accounts", headers=_headers(raw))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    users = {u["name"]: u for u in body["users"]}
    assert users["root"]["system"] is True and users["deploy"]["system"] is False
    assert users["deploy"]["uid"] == 1001 and users["deploy"]["home"] == "/home/deploy"
    groups = {g["name"]: g for g in body["groups"]}
    assert groups["sudo"]["members"] == ["deploy"] and groups["sudo"]["system"] is True
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_manage_user_create_and_delete(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    fake = AccountsFake()
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        r1 = client.post(f"/api/v1/agents/{agent.id}/accounts/user", json={"name": "bob", "state": "present"}, headers=_headers(raw))
        r2 = client.post(f"/api/v1/agents/{agent.id}/accounts/user", json={"name": "bob", "state": "absent", "remove": True}, headers=_headers(raw))
    assert r1.status_code == 200 and r2.status_code == 200
    names = [(n, b) for (n, b) in fake.calls if n == "user"]
    assert names[0][1]["name"] == "bob" and names[0][1]["state"] == "present"
    assert names[1][1]["state"] == "absent" and names[1][1]["remove"] is True
    # None-valued fields (uid/shell/…) are dropped, not forwarded as null.
    assert "uid" not in names[0][1] and "shell" not in names[0][1]
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_manage_group_rejects_bad_state(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    with TestClient(create_app()) as client:
        resp = client.post(f"/api/v1/agents/{agent.id}/accounts/group", json={"name": "x", "state": "weird"}, headers=_headers(raw))
    assert resp.status_code == 422
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


# ---- J4d: storage overview ------------------------------------------------


class StorageFake:
    """storage_facts + zpool_facts envelopes; zpool_facts can be made absent."""

    def __init__(self, zfs_absent: bool = False):
        self.zfs_absent = zfs_absent
        self.calls: list[str] = []

    async def call_tool(self, name, body):
        self.calls.append(name)
        if name == "storage_facts":
            return {"changed": False, "data": {
                "block_devices": {"available": True, "devices": [{"name": "sda", "size": "100G", "type": "disk"}]},
                "lvm": {"available": True, "vgs": [{"vg_name": "datavg"}], "pvs": [], "lvs": [{"lv_name": "data1"}]},
                "vdo": {"available": False, "error": "not found"},
            }}
        if name == "community.general.zpool_facts":
            if self.zfs_absent:
                raise AgentClientError("docker-test:18051: tool 'community.general.zpool_facts' returned 422: zfs absent")
            return {"changed": False, "data": {"pools": [{"name": "tank"}]}}
        raise AgentClientError("unexpected " + name)


async def test_storage_aggregates_facts_and_zfs(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    fake = StorageFake()
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/storage", headers=_headers(raw))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["lvm"]["available"] is True and body["lvm"]["vgs"][0]["vg_name"] == "datavg"
    assert body["block_devices"]["devices"][0]["name"] == "sda"
    assert body["vdo"]["available"] is False
    assert body["zfs"]["available"] is True and body["zfs"]["pools"][0]["name"] == "tank"
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_storage_degrades_when_zfs_absent(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    fake = StorageFake(zfs_absent=True)
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/storage", headers=_headers(raw))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    # storage_facts still there; zfs section degrades rather than 502-ing.
    assert body["lvm"]["available"] is True
    assert body["zfs"]["available"] is False and "error" in body["zfs"]
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


# ---- J4e: network ---------------------------------------------------------


async def test_network_gathered(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    gathered = {"changed": False, "data": {
        "interfaces": [{"name": "eth0", "state": "UP", "addresses": [{"family": "inet", "cidr": "10.0.0.5/24"}]}],
        "routes": [{"raw": "default via 10.0.0.1 dev eth0", "dest": "default", "gateway": "10.0.0.1", "dev": "eth0"}],
        "dns": {"nameservers": ["1.1.1.1"], "search": []},
    }}
    fake = CallToolFake(result=gathered)
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/network", headers=_headers(raw))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["interfaces"][0]["name"] == "eth0"
    assert body["dns"]["nameservers"] == ["1.1.1.1"]
    assert fake.calls == [("yoloman.network_interface", {"state": "gathered"})]
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_network_configure_forwards_params(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    fake = CallToolFake(result={"changed": True, "msg": "modified connection eth0 (static)"})
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.post(
            f"/api/v1/agents/{agent.id}/network",
            json={"name": "eth0", "state": "present", "method": "static", "address": "10.0.0.5/24", "gateway": "10.0.0.1", "dry_run": True},
            headers=_headers(raw),
        )
    assert resp.status_code == 200, resp.text
    name, params = fake.calls[0]
    assert name == "yoloman.network_interface"
    assert params["method"] == "static" and params["address"] == "10.0.0.5/24" and params["dry_run"] is True
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


# ---- Virtualization -------------------------------------------------------


async def test_virt_overview(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    facts = {"changed": False, "data": {
        "hypervisors": ["proxmox"],
        "proxmox": {"available": True, "vms": [{"vmid": "100", "name": "web01", "status": "running"}], "containers": []},
        "libvirt": {"available": False, "error": "not found"},
    }}
    fake = CallToolFake(result=facts)
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.get(f"/api/v1/agents/{agent.id}/virt", headers=_headers(raw))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["hypervisors"] == ["proxmox"]
    assert body["proxmox"]["vms"][0]["name"] == "web01"
    assert body["libvirt"]["available"] is False
    assert fake.calls == [("virt_facts", {})]
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


# ---- J4a: enable/disable via service-control ------------------------------


async def test_service_control_enable_maps_to_enabled_true(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    fake = CallToolFake(result={"changed": True, "msg": "state applied"})
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.post(
            f"/api/v1/agents/{agent.id}/service-control",
            json={"service": "nginx", "action": "enable"},
            headers=_headers(raw),
        )
    assert resp.status_code == 200, resp.text
    assert resp.json()["action"] == "enable"
    assert fake.calls == [("systemd", {"name": "nginx", "enabled": True})]
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_service_control_disable_maps_to_enabled_false(db_session):
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    fake = CallToolFake(result={"changed": True, "msg": "state applied"})
    app = create_app()
    _override(app, fake)
    with TestClient(app) as client:
        resp = client.post(
            f"/api/v1/agents/{agent.id}/service-control",
            json={"service": "nginx", "action": "disable"},
            headers=_headers(raw),
        )
    assert resp.status_code == 200, resp.text
    assert fake.calls == [("systemd", {"name": "nginx", "enabled": False})]
    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


# ---- diagnosis (plan B8/B9): ask, list, read, export — through the app, with the host ACL -------------------


async def test_diagnosis_routes_ask_list_read_and_export(db_session):
    import json as _json
    from pathlib import Path as _Path

    doc = _json.loads((_Path(__file__).resolve().parents[2] / "configs/schemas/diagnosis.examples/windows-dependency.json").read_text())
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)
    app = create_app()
    _override(app, CallToolFake(result={"changed": False, "data": {"diagnosis": doc}}))
    with TestClient(app) as client:
        asked = client.post(f"/api/v1/agents/{agent.id}/diagnose", json={"name": "yoloman-probe-dep"}, headers=_headers(raw))
        assert asked.status_code == 200, asked.text
        row_id = asked.json()["id"]
        listed = client.get(f"/api/v1/agents/{agent.id}/diagnoses", headers=_headers(raw))
        read = client.get(f"/api/v1/diagnoses/{row_id}", headers=_headers(raw))
        exported = client.get(f"/api/v1/diagnoses/{row_id}/export/dsc", headers=_headers(raw))
        unknown = client.get(f"/api/v1/diagnoses/{row_id}/export/pdf", headers=_headers(raw))
        anonymous = client.get(f"/api/v1/diagnoses/{row_id}")

    assert asked.json()["contract_status"] == "ok"
    assert [i["id"] for i in listed.json()["items"]] == [row_id]
    assert read.status_code == 200 and read.json()["diagnosis"] == doc
    assert exported.status_code == 200 and "Microsoft.Windows/Service" in exported.json()["apply"]
    assert unknown.status_code == 422 and anonymous.status_code == 401

    await db_session.delete(api_token)
    await db_session.delete(agent)
    await db_session.commit()


async def test_diagnosis_gelf_send_route(db_session):
    """POST /export/gelf/send puts the diagnosis on the wire: a local UDP socket stands in for Graylog, and the
    endpoint must report what it sent AND the datagrams must arrive. With no target configured it is a named 422."""
    import json as _json
    import socket as _socket
    from pathlib import Path as _Path
    from bossman.config import Settings, get_settings

    doc = _json.loads((_Path(__file__).resolve().parents[2] / "configs/schemas/diagnosis.examples/windows-dependency.json").read_text())
    agent = await _make_agent(db_session)
    api_token, raw = await _make_api_token(db_session)

    srv = _socket.socket(_socket.AF_INET, _socket.SOCK_DGRAM)
    srv.bind(("127.0.0.1", 0))
    srv.settimeout(5)
    port = srv.getsockname()[1]
    try:
        # No target: the export still produces, but SENDING refuses with the reason.
        app_off = create_app()
        _override(app_off, CallToolFake(result={"changed": False, "data": {"diagnosis": doc}}))
        with TestClient(app_off) as client:
            row_id = client.post(f"/api/v1/agents/{agent.id}/diagnose", json={"name": "yoloman-probe-dep"},
                                 headers=_headers(raw)).json()["id"]
            off = client.post(f"/api/v1/diagnoses/{row_id}/export/gelf/send", headers=_headers(raw))
        assert off.status_code == 422 and "BOSSMAN_GELF_HOST" in off.json()["detail"]

        # Target configured: the endpoint sends, and the datagrams land on the socket.
        app_on = create_app()
        _override(app_on, CallToolFake(result={"changed": False, "data": {"diagnosis": doc}}))
        app_on.dependency_overrides[get_settings] = lambda: Settings(gelf_host="127.0.0.1", gelf_port=port, gelf_protocol="udp")
        with TestClient(app_on) as client:
            sent = client.post(f"/api/v1/diagnoses/{row_id}/export/gelf/send", headers=_headers(raw))
        assert sent.status_code == 200, sent.text
        body = sent.json()
        assert body["sent"] == body["datagrams"] and body["sent"] >= 1
        assert body["transport"] == f"udp://127.0.0.1:{port}"
        got = []
        for _ in range(body["datagrams"]):
            data, _addr = srv.recvfrom(65535)
            got.append(_json.loads(data))
        assert {m["_correlation_id"] for m in got} == {doc["diagnosis_id"]}
        assert any(m.get("_kind") == "finding" for m in got)
    finally:
        srv.close()
        await db_session.delete(api_token)
        await db_session.delete(agent)
        await db_session.commit()


async def test_a_stored_diagnosis_follows_its_hosts_acl(db_session):
    from bossman.services.auth import new_api_token as _new
    from bossman.services.diagnosis import store

    agent = await _make_agent(db_session)
    row = await store(db_session, agent, {"diagnosis_id": "acl-run", "platform": "linux", "target": {"name": "x"},
                                          "status": "running", "evidence": [], "findings": []})
    tok, raw = _new("no-grant-caller")
    db_session.add(tok)
    await db_session.commit()
    with TestClient(create_app()) as client:
        resp = client.get(f"/api/v1/diagnoses/{row.id}", headers=_headers(raw))
    assert resp.status_code == 403

    await db_session.delete(tok)
    await db_session.delete(agent)
    await db_session.commit()
