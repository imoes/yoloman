"""Every MCP tool refuses an argument it does not declare, and call_agent_tool takes its own timeout.

Pinned: `call_agent_tool(..., arguments={...})` (the field is `params`) used to run with NO params and fail later
with the agent's misleading "missing required parameter"; now it fails at once, names the unknown key and the
closest declared one, and the schema says additionalProperties=false. timeout_seconds reaches the agent client.
"""
from __future__ import annotations

import pytest
from mcp.server.fastmcp.exceptions import ToolError

from bossman.mcp.server import build_mcp_server
from bossman.services.catalog import CatalogCache
from tests.test_mcp_server import FakeEmbeddingClient, _call, _make_agent, _settings, session_factory  # noqa: F401


class _Agent:
    def __init__(self):
        self.calls: list[tuple] = []

    async def call_tool(self, name, body, timeout=None):
        self.calls.append((name, body, timeout))
        return {"changed": False, "msg": "ok", "data": {}}


async def test_unknown_arguments_are_refused_with_the_closest_name(db_session, session_factory, tmp_path):
    agent = await _make_agent(db_session, address="10.250.7.7:18051")
    fake = _Agent()
    mcp = build_mcp_server(session_factory, _settings(str(tmp_path)), CatalogCache(str(tmp_path)), FakeEmbeddingClient(),
                           client_factory=lambda a, s: fake)
    with pytest.raises(ToolError, match=r"unknown parameter 'arguments' \(did you mean 'params'\?\)"):
        await _call(mcp, "call_agent_tool", {"host": agent.name, "tool": "setup", "arguments": {"x": 1}})
    assert fake.calls == []
    tools = {t.name: t for t in await mcp.list_tools()}
    assert tools["call_agent_tool"].inputSchema.get("additionalProperties") is False
    assert all(t.inputSchema.get("additionalProperties") is False for t in tools.values())

    # Declared arguments still work, and timeout_seconds reaches the client; without it nothing extra is sent.
    await _call(mcp, "call_agent_tool", {"host": agent.name, "tool": "yoloman.scx_install", "params": {"wait": 0},
                                         "timeout_seconds": 1200})
    await _call(mcp, "call_agent_tool", {"host": agent.name, "tool": "setup"})
    assert fake.calls == [("yoloman.scx_install", {"wait": 0}, 1200.0), ("setup", {}, None)]
    with pytest.raises(ToolError, match="between 1 and 7200"):
        await _call(mcp, "call_agent_tool", {"host": agent.name, "tool": "setup", "timeout_seconds": 0})
