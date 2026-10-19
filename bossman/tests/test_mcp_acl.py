"""The MCP facade applies the host ACL that REST applies (services.auth.user_can_manage_agent).

Measured before this existed: an API token with no grant at all ran `command` and `reboot` on a host
through call_agent_tool, while REST refused the same token with 403. Pinned here: a tool that contacts a
host's agent (or runs something against it) needs a grant covering that host; a grant for one host does
not cover another; reading Bossman's own records stays open, as over REST; a call without any identity
(that did not pass the bearer middleware) is refused.
"""
from __future__ import annotations

import pytest
from mcp.server.fastmcp.exceptions import ToolError

from bossman.db.models import AccessGrant
from bossman.mcp.auth import current_auth_identity
from bossman.mcp.server import build_mcp_server
from bossman.services.auth import Identity, new_api_token
from bossman.services.catalog import CatalogCache
from tests.test_mcp_server import FakeAgentClient, FakeEmbeddingClient, _call, _make_agent, _settings, session_factory  # noqa: F401


async def _token(db_session, name, **grant):
    row, _raw = new_api_token(name)
    db_session.add(row)
    await db_session.flush()
    if grant:
        db_session.add(AccessGrant(subject_kind="api_token", subject_ref=name, subject_token_id=row.id, **grant))
    await db_session.commit()
    return row


def _as(row):
    return current_auth_identity.set(Identity(kind="api_token", name=row.name, token_id=row.id))


async def test_host_tools_need_a_grant_covering_the_host(db_session, session_factory, tmp_path):
    mine = await _make_agent(db_session)
    other = await _make_agent(db_session)
    fake = FakeAgentClient()
    mcp = build_mcp_server(session_factory, _settings(str(tmp_path)), CatalogCache(str(tmp_path)),
                           FakeEmbeddingClient(), client_factory=lambda a, s: fake)
    nogrant = await _token(db_session, "acl-none")
    hostgrant = await _token(db_session, "acl-host", scope="host", agent_id=mine.id)
    try:
        tok = _as(nogrant)
        try:
            for tool, args in [
                ("call_agent_tool", {"host": mine.name, "tool": "command", "params": {"argv": ["true"]}}),
                ("call_agent_tool", {"host": mine.name, "tool": "reboot"}),
                ("list_agent_tools", {"host": mine.name}),
                ("resource_apply", {"host": mine.name, "kind": "service", "name": "cron",
                                    "desired": {"state": "started"}, "dry_run": False}),
            ]:
                with pytest.raises(ToolError, match="not authorized to manage"):
                    await _call(mcp, tool, args)
            assert fake.tool_calls == [], "a refused call must never reach the agent"
            # Bossman's own records stay readable, as over REST.
            status = await _call(mcp, "host_status", {"host": mine.name})
            assert isinstance(status, dict) and status, "host_status reads Bossman's records and needs no grant"
        finally:
            current_auth_identity.reset(tok)

        tok = _as(hostgrant)
        try:
            await _call(mcp, "call_agent_tool", {"host": mine.name, "tool": "command", "params": {"argv": ["true"]}})
            assert fake.tool_calls == [("command", {"argv": ["true"]})]
            with pytest.raises(ToolError, match=f"not authorized to manage '{other.name}'"):
                await _call(mcp, "call_agent_tool", {"host": other.name, "tool": "command", "params": {"argv": ["true"]}})
        finally:
            current_auth_identity.reset(tok)

        tok = current_auth_identity.set(None)
        try:
            with pytest.raises(ToolError, match="not authorized"):
                await _call(mcp, "call_agent_tool", {"host": mine.name, "tool": "command", "params": {"argv": ["true"]}})
        finally:
            current_auth_identity.reset(tok)
    finally:
        for row in (mine, other, nogrant, hostgrant):
            await db_session.delete(row)
        await db_session.commit()


async def test_set_netboot_needs_an_all_hosts_grant(db_session, session_factory, tmp_path):
    """Fleet-wide switch: a host grant is not enough. Only the refusal is exercised — a passing call would flip
    the shared DB's real netboot toggle."""
    mine = await _make_agent(db_session)
    hostgrant = await _token(db_session, "acl-netboot-host", scope="host", agent_id=mine.id)
    mcp = build_mcp_server(session_factory, _settings(str(tmp_path)), CatalogCache(str(tmp_path)),
                           FakeEmbeddingClient(), client_factory=lambda a, s: FakeAgentClient())
    tok = _as(hostgrant)
    try:
        with pytest.raises(ToolError, match="needs an 'all' grant"):
            await _call(mcp, "set_netboot", {"enabled": True})
    finally:
        current_auth_identity.reset(tok)
        await db_session.delete(mine)
        await db_session.delete(hostgrant)
        await db_session.commit()
