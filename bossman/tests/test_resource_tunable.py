"""Kernel tunables as a Resource (docs/kernel-tuning.md, block 4), driven through the MCP tools.

DB-backed (the generations are real rows), with a fake agent that behaves like the yoloman.<tunable>
modules: check mode predicts, a real call changes, every answer carries before/after/persistence and the
undo that restores the state before it. The point under test is the contract the tuning loop will rely
on: plan → apply records a generation with its undo; a repeated apply records nothing; observe reports
drift; rollback(0) gives back the state before yoloman managed the tunable; a module refusal keeps its
kind.
"""
from __future__ import annotations

import pytest

from bossman.mcp.server import build_mcp_server
from bossman.services.agent_client import AgentClientError
from bossman.services.catalog import CatalogCache
from bossman.services.resources import tunable as tun
from tests.test_mcp_server import FakeEmbeddingClient, _call, _make_agent, _settings, session_factory  # noqa: F401


class FakeTunableAgent:
    """systemd_resource with one unit's properties in a dict; sched_ext always refused."""

    def __init__(self):
        self.props = {"CPUWeight": "", "MemoryHigh": "infinity"}
        self.dropin = False
        self.calls: list[tuple[str, dict]] = []

    async def call_tool(self, name, body):
        self.calls.append((name, dict(body)))
        if name == "yoloman.sched_ext":
            raise AgentClientError('10.0.0.7:8010: tool \'yoloman.sched_ext\' returned 500: {"error":"fail: '
                                   'unsupported: sched_ext is unsupported (CONFIG_SCHED_CLASS_EXT=n in /boot/config-6.12)"}')
        assert name == "yoloman.systemd_resource", name
        dry = bool(body.get("dry_run"))
        want = {k: str(v) for k, v in (body.get("properties") or {}).items()}
        before = {k: self.props.get(k, "") for k in want}
        had = self.dropin
        if body.get("state") == "absent":
            changed = had or before != want
            if not dry:
                self.dropin = False
                self.props.update(want)
            return {"changed": changed, "msg": "", "data": {"before": before, "after": want, "persistence": "live"}}
        changed = before != want or not had
        if not dry:
            self.props.update(want)
            self.dropin = True
        undo = {"unit": body["unit"], "properties": before}
        undo.update({"persistent": True} if had else {"state": "absent"})
        return {"changed": changed, "msg": "", "data": {"before": before, "after": want, "persistence": "persistent",
                                                        "backend": "/etc/systemd/system/x.d/90-yoloman-resource.conf",
                                                        "rollback": undo}}

    async def list_tools(self):
        return []


def test_names_are_validated_with_their_reason():
    assert tun.parse_name("systemd_resource:cron.service") == ("systemd_resource", "cron.service")
    assert tun.parse_name("sched_ext") == ("sched_ext", None)
    with pytest.raises(tun.TunableError, match="address it as systemd_resource:<unit>"):
        tun.parse_name("systemd_resource")
    with pytest.raises(tun.TunableError, match="one per host"):
        tun.parse_name("sched_ext:cpu0")
    with pytest.raises(tun.TunableError, match="unknown tunable 'nice'"):
        tun.parse_name("nice")


def test_refusals_keep_their_kind():
    msg = 'tool returned 500: {"error":"fail: tool_unavailable: scx_lavd is not installed"}'
    assert tun.classify_refusal(msg) == {"kind": "tool_unavailable", "reason": "scx_lavd is not installed"}
    assert tun.classify_refusal("connection reset")["kind"] == "error"


async def test_tunable_plan_apply_observe_rollback_over_mcp(db_session, session_factory, tmp_path):
    agent = await _make_agent(db_session)
    fake = FakeTunableAgent()
    mcp = build_mcp_server(session_factory, _settings(str(tmp_path)), CatalogCache(str(tmp_path)),
                           FakeEmbeddingClient(), client_factory=lambda a, s: fake)
    host, name = agent.name, "systemd_resource:cron.service"
    desired = {"params": {"properties": {"CPUWeight": 50, "MemoryHigh": "128M"}}}
    try:
        obs = await _call(mcp, "resource_observe", {"host": host, "kind": "tunable", "name": name})
        assert obs["observed"] == {"tunable": "systemd_resource", "target": "cron.service", "managed": False}

        plan = await _call(mcp, "resource_plan", {"host": host, "kind": "tunable", "name": name, "desired": desired})
        assert plan["action"] == "update"
        assert plan["changed"]["CPUWeight"] == ["", "50"]
        assert plan["rollback"]["state"] == "absent"
        # the target comes from the name, the call ran in check mode
        assert fake.calls[-1] == ("yoloman.systemd_resource",
                                  {"properties": {"CPUWeight": 50, "MemoryHigh": "128M"}, "unit": "cron.service", "dry_run": True})
        assert fake.props["CPUWeight"] == ""

        res = await _call(mcp, "resource_apply", {"host": host, "kind": "tunable", "name": name, "desired": desired, "dry_run": False})
        assert res["ok"] and res["generation"] == 1
        assert fake.props == {"CPUWeight": "50", "MemoryHigh": "128M"}

        again = await _call(mcp, "resource_apply", {"host": host, "kind": "tunable", "name": name, "desired": desired, "dry_run": False})
        assert again["ok"] and again["generation"] is None, "an unchanged apply must not add a generation"

        gens = await _call(mcp, "resource_generations", {"host": host, "kind": "tunable", "name": name})
        assert [g["generation"] for g in gens] == [1]
        assert gens[0]["spec"]["undo"] == {"unit": "cron.service", "properties": {"CPUWeight": "", "MemoryHigh": "infinity"},
                                           "state": "absent"}

        obs = await _call(mcp, "resource_observe", {"host": host, "kind": "tunable", "name": name})
        assert obs["observed"]["managed"] and obs["observed"]["drift"] is False
        fake.props["CPUWeight"] = "100"  # someone changed it on the host
        obs = await _call(mcp, "resource_observe", {"host": host, "kind": "tunable", "name": name})
        assert obs["observed"]["drift"] is True

        back = await _call(mcp, "resource_rollback", {"host": host, "kind": "tunable", "name": name, "generation": 0})
        assert back["ok"] and back["generation"] == 2
        assert fake.props == {"CPUWeight": "", "MemoryHigh": "infinity"} and fake.dropin is False
    finally:
        await db_session.delete(agent)
        await db_session.commit()


async def test_tunable_refusal_and_contradicting_target(db_session, session_factory, tmp_path):
    agent = await _make_agent(db_session)
    fake = FakeTunableAgent()
    mcp = build_mcp_server(session_factory, _settings(str(tmp_path)), CatalogCache(str(tmp_path)),
                           FakeEmbeddingClient(), client_factory=lambda a, s: fake)
    try:
        plan = await _call(mcp, "resource_plan", {"host": agent.name, "kind": "tunable", "name": "sched_ext",
                                                  "desired": {"params": {"scheduler": "bpfland"}}})
        assert plan["action"] == "refused"
        assert plan["refusal"]["kind"] == "unsupported"
        assert "CONFIG_SCHED_CLASS_EXT=n" in plan["refusal"]["reason"]
        res = await _call(mcp, "resource_apply", {"host": agent.name, "kind": "tunable", "name": "sched_ext",
                                                  "desired": {"params": {"scheduler": "bpfland"}}, "dry_run": False})
        assert res["ok"] is False and res["plan"]["action"] == "refused"
        assert [n for n, _ in fake.calls] == ["yoloman.sched_ext", "yoloman.sched_ext"], "a refused plan must not be applied"

        from mcp.server.fastmcp.exceptions import ToolError
        with pytest.raises(ToolError, match="addresses unit='cron.service'"):
            await _call(mcp, "resource_plan", {"host": agent.name, "kind": "tunable", "name": "systemd_resource:cron.service",
                                               "desired": {"params": {"unit": "ssh.service", "properties": {"CPUWeight": 5}}}})
    finally:
        await db_session.delete(agent)
        await db_session.commit()


async def test_mcp_resource_tools_reach_every_registered_kind(db_session, session_factory, tmp_path):
    """MCP used to build resources through its own if-chain that knew docker|helm|config|role only;
    `package` and `service` existed over REST but not over MCP. Now both go through the registry."""
    agent = await _make_agent(db_session)

    class _Agent:
        async def call_tool(self, name, body):
            return {"changed": False, "data": {"stdout": "active\n---\nenabled\n"}}

    mcp = build_mcp_server(session_factory, _settings(str(tmp_path)), CatalogCache(str(tmp_path)),
                           FakeEmbeddingClient(), client_factory=lambda a, s: _Agent())
    try:
        got = await _call(mcp, "resource_observe", {"host": agent.name, "kind": "service", "name": "cron"})
        assert got["observed"]["state"] == "started" and got["observed"]["enabled"] is True
        from mcp.server.fastmcp.exceptions import ToolError
        with pytest.raises(ToolError, match="tunable"):
            await _call(mcp, "resource_observe", {"host": agent.name, "kind": "nonsense", "name": "x"})
    finally:
        await db_session.delete(agent)
        await db_session.commit()
