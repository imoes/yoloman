"""GET /api/v1/agents/{id}/processes — an on-demand pass-through to one
agent's live process table (Block J1).

Unlike api/agents.py (which serves Bossman's already-aggregated Postgres
data), a process list is a *live* snapshot the agent samples per request —
"which process is eating the box right now" — so it is never stored or
polled ahead of time. This route builds the same mTLS AgentClient the poller
and plan runs use and proxies the call through, translating an unreachable
agent into a clean HTTP error rather than a stack trace.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent
from bossman.db.session import get_session
from bossman.services.agent_client import AgentClientError

router = APIRouter()


@router.get("/api/v1/agents/{agent_id}/processes")
async def get_agent_processes(
    agent_id: UUID,
    limit: int = Query(0, ge=0, le=10000, description="Keep only the top-N hungriest processes (0 = all)"),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")
    if not agent.address:
        raise HTTPException(status_code=422, detail=f"agent {agent.name!r} has no reachable address")

    client = client_factory(agent, settings)
    try:
        return await client.processes(limit=limit)
    except AgentClientError as exc:
        # The agent is unreachable / errored — a gateway problem, not a
        # client one, so 502 (mirrors how a proxy reports an upstream fault).
        raise HTTPException(status_code=502, detail=str(exc)) from exc
