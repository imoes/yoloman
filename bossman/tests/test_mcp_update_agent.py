"""The MCP tool update_agent and the REST route update-bundled share services/agent_update.py.

What is pinned here: the MCP tool authorises against the host ACL exactly like REST (a token without a
grant is refused, with the way to fix it); dry_run names the package without pushing; the push reaches
the agent's self-update with the bundled bytes; a host whose OS family is unknown is refused instead of
being sent the .deb (the old REST behaviour).
"""
from __future__ import annotations

import hashlib

import pytest
from mcp.server.fastmcp.exceptions import ToolError

from bossman.db.models import AccessGrant
from bossman.mcp.auth import current_auth_identity
from bossman.mcp.server import build_mcp_server
from bossman.services.auth import Identity, new_api_token
from bossman.services.catalog import CatalogCache
from tests.test_mcp_server import FakeEmbeddingClient, _call, _make_agent, _settings, session_factory  # noqa: F401


class _Agent:
    def __init__(self):
        self.pushed: list[bytes] = []

    async def self_update(self, data: bytes):
        self.pushed.append(data)
        return {"status": "accepted", "bytes": len(data)}


async def _token(db_session, name, grant: bool):
    row, _raw = new_api_token(name)
    db_session.add(row)
    await db_session.flush()
    if grant:
        db_session.add(AccessGrant(subject_kind="api_token", subject_ref=name, subject_token_id=row.id, scope="all"))
    await db_session.commit()
    return row


async def test_update_agent_follows_the_host_acl_and_the_os_family(db_session, session_factory, tmp_path):
    deb = tmp_path / "agent.deb"
    deb.write_bytes(b"!<arch>\nfake-deb")
    settings = _settings(str(tmp_path), agent_deb_path=str(deb), agent_rpm_path=str(tmp_path / "missing.rpm"))
    debian = await _make_agent(db_session, facts={"os": {"id": "debian"}}, agent_version="0.57.93")
    unknown = await _make_agent(db_session, facts={})
    fake = _Agent()
    mcp = build_mcp_server(session_factory, settings, CatalogCache(str(tmp_path)), FakeEmbeddingClient(),
                           client_factory=lambda a, s: fake)
    no_grant = await _token(db_session, "upd-nogrant", grant=False)
    granted = await _token(db_session, "upd-granted", grant=True)
    try:
        tok = current_auth_identity.set(Identity(kind="api_token", name=no_grant.name, token_id=no_grant.id))
        try:
            with pytest.raises(ToolError, match="not authorized to manage"):
                await _call(mcp, "update_agent", {"host": debian.name})
        finally:
            current_auth_identity.reset(tok)

        tok = current_auth_identity.set(Identity(kind="api_token", name=granted.name, token_id=granted.id))
        try:
            plan = await _call(mcp, "update_agent", {"host": debian.name})
            assert plan["dry_run"] is True and plan["package"] == "deb" and plan["current_version"] == "0.57.93"
            assert plan["sha256"] == hashlib.sha256(b"!<arch>\nfake-deb").hexdigest()
            assert fake.pushed == [], "a dry run must not push"

            done = await _call(mcp, "update_agent", {"host": debian.name, "dry_run": False})
            assert done["result"]["status"] == "accepted" and fake.pushed == [b"!<arch>\nfake-deb"]

            with pytest.raises(ToolError, match="OS family .* is 'unknown'"):
                await _call(mcp, "update_agent", {"host": unknown.name})
        finally:
            current_auth_identity.reset(tok)
    finally:
        for row in (debian, unknown, no_grant, granted):
            await db_session.delete(row)
        await db_session.commit()
