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

from datetime import datetime
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import text
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


@router.get("/api/v1/agents/{agent_id}/processes/history")
async def get_process_history(
    agent_id: UUID,
    comm: str = Query(..., description="Command name (comm) to fetch CPU/RSS history for"),
    since: datetime | None = Query(None, description="Only points at or after this time"),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """CPU% + RSS history for one process, keyed by command name (comm) — the
    combined-graph source behind an expanded Processes-tab row. History is
    tracked per comm, not per pid, so it stays continuous across a service
    restart (a restart changes the pid but not the comm) and doesn't accumulate
    dead-pid series. Reads the agent's `process_cpu_percent` /
    `process_rss_bytes` series (aggregated per comm) straight from stored
    metrics. Raw tier only — the 14-day raw retention ages out old data."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")

    async def _series(metric: str) -> list[Any]:
        stmt = text(
            "SELECT time, value FROM metrics "
            "WHERE agent_id = :agent_id AND metric = :metric AND labels->>'comm' = :comm "
            + ("AND time >= :since " if since is not None else "")
            + "ORDER BY time"
        )
        params: dict[str, Any] = {"agent_id": str(agent_id), "metric": metric, "comm": comm}
        if since is not None:
            params["since"] = since
        return (await session.execute(stmt, params)).all()

    cpu_rows = await _series("process_cpu_percent")
    rss_rows = await _series("process_rss_bytes")
    return {
        "comm": comm,
        "cpu_percent": [{"time": r.time.isoformat(), "value": r.value} for r in cpu_rows],
        "rss_bytes": [{"time": r.time.isoformat(), "value": r.value} for r in rss_rows],
    }


@router.get("/api/v1/agents/{agent_id}/ebpf")
async def get_agent_ebpf(
    agent_id: UUID,
    limit: int = Query(20, ge=1, le=200),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict:
    """On-demand eBPF detail behind the host's latency heatmaps — the 'what':
    the top outbound connection targets (comm → dst:port, connects) and the
    slowest recent block-I/O requests (comm, device, latency, op). Live
    pass-through to the agent, never stored."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")
    if not agent.address:
        raise HTTPException(status_code=422, detail=f"agent {agent.name!r} has no reachable address")

    client = client_factory(agent, settings)
    try:
        talkers = await client.ebpf_top_talkers(limit=limit)
        disk = await client.ebpf_slowest_disk_io(limit=limit)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {
        "top_talkers": talkers.get("top_talkers", []),
        "slowest_disk_io": disk.get("disk_io", []),
    }
