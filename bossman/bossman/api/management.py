"""Block J4 — Cockpit-artige Host-Verwaltung: live pass-through reads (and a
few actions) for the per-host management page (Services / Logs / Accounts /
Storage / Network).

Like api/processes.py these are *live* pulls proxied to one agent, never
Bossman's aggregated Postgres data. Every read is a read-only agent *module*
(service_facts / journal / getent / storage_facts / …), so it goes through the
same `call_tool` path the plan engine uses (POST /api/v1/tools/{name}). Write
actions live next to service_control in api/agents.py; this router is mostly
reads plus the aggregate helpers the UI needs.

The agent's write gate is the only access control on mutating tools: a
read-only agent returns 403, surfaced here as a 502 with the agent's message.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent
from bossman.db.session import get_session
from bossman.services.agent_client import AgentClientError

router = APIRouter()


async def _agent_with_address(session: AsyncSession, agent_id: UUID) -> Agent:
    """Resolve an agent that can be reached directly, or raise the same
    404/422 an on-demand read uses (mirrors api/processes.py)."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")
    if not agent.address:
        raise HTTPException(status_code=422, detail=f"agent {agent.name!r} has no reachable address")
    return agent


# ---- Generic tool router (the REST counterpart to Bossman's MCP router) ----
#
# Bossman's MCP server acts as a gateway: an MCP client sees the fleet of
# managed agents and each agent's tools, and routes calls through Bossman to
# the agent. These two routes are the REST equivalent the UI (and any HTTP
# client) uses; the MCP tools list_agent_tools / call_agent_tool in
# bossman/mcp/server.py are thin wrappers over exactly this proxy.


class ToolCallRequest(BaseModel):
    # The tool's own params; dry_run is honored by write modules themselves.
    params: dict[str, Any] = {}


@router.get("/api/v1/agents/{agent_id}/tools")
async def list_agent_tools_route(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Every tool one managed agent currently exposes ([{name, kind, writes}]),
    proxied from the agent's own GET /api/v1/tools. Write tools appear only
    when that agent's write gate is open."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        tools = await client.list_tools()
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "tools": tools}


@router.post("/api/v1/agents/{agent_id}/tools/{tool_name}")
async def call_agent_tool_route(
    agent_id: UUID,
    tool_name: str,
    body: ToolCallRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Route a single tool call to one managed agent (proxies the agent's
    POST /api/v1/tools/{name}). The agent's write gate + ACL + audit are the
    enforcement point; a read-only agent rejecting a write tool surfaces as a
    502 with the agent's message."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool(tool_name, body.params)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "tool": tool_name, "result": result}


@router.get("/api/v1/agents/{agent_id}/services")
async def get_agent_services(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Block J4a — the host's systemd service units + their load/active/sub
    state, via the read-only `service_facts` module. The UI drives its
    per-unit start/stop/restart/enable/disable off this list (each action
    goes to POST /agents/{id}/service-control)."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool("service_facts", {})
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    # call_tool returns the agent's tool envelope {changed, msg, data}; the
    # unit list is under data. Pass it through in a stable shape for the UI.
    services = (result or {}).get("data") if isinstance(result, dict) else None
    return {"agent_id": str(agent.id), "services": services or []}


@router.get("/api/v1/agents/{agent_id}/logs")
async def get_agent_logs(
    agent_id: UUID,
    lines: int = Query(200, ge=1, le=5000, description="Most recent N journal entries"),
    unit: str | None = Query(None, description="Restrict to one systemd unit"),
    priority: str | None = Query(None, description="Syslog priority (0-7 or a name like 'err')"),
    since: str | None = Query(None, description="journalctl time spec, e.g. '-1h' or 'yesterday'"),
    grep: str | None = Query(None, description="MESSAGE regex"),
    boot: bool = Query(False, description="Current boot only"),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Block J4b — the host's journald log, via the read-only `journal`
    module (`journalctl -o json`). Filters map 1:1 to the module's params."""
    agent = await _agent_with_address(session, agent_id)
    params: dict[str, Any] = {"lines": lines, "boot": boot}
    if unit:
        params["unit"] = unit
    if priority:
        params["priority"] = priority
    if since:
        params["since"] = since
    if grep:
        params["grep"] = grep
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool("journal", params)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    data = (result or {}).get("data") if isinstance(result, dict) else None
    data = data or {}
    return {"agent_id": str(agent.id), "entries": data.get("entries") or [], "count": data.get("count") or 0}
