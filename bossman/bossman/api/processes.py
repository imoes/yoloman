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

import asyncio
import socket
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
    top_talkers = talkers.get("top_talkers", [])

    # BCC-inspired signals (oomkill/tcpretrans/killsnoop/runqlat). Each is
    # best-effort and independent: an older agent without these endpoints (404)
    # or a kernel where a probe didn't attach just yields an empty section, so
    # the heatmaps/talkers above still render.
    async def _soft(coro):
        try:
            return await coro
        except AgentClientError:
            return {}

    oom = await _soft(client.ebpf_oom_kills(limit=limit))
    retrans = await _soft(client.ebpf_tcp_retransmits(limit=limit))
    sigs = await _soft(client.ebpf_signals(limit=limit))
    runq = await _soft(client.ebpf_runq_latency())
    l7 = await _soft(client.ebpf_l7_requests(limit=max(limit, 50)))
    tcp_retransmits = retrans.get("retransmits", [])
    l7_events = l7.get("events", [])

    # Build an IP→hostname map from the host's OWN observed DNS answers (coroot's
    # ip_to_fqdn). This names targets that have a forward A record but no reverse
    # PTR — common in FreeIPA/AD, whose reverse zones are often incomplete (e.g.
    # freeipa01.ipa.example.com resolves forward to 192.0.2.97 but has no PTR),
    # which best-effort _rdns alone can never resolve. Used as the fallback after
    # PTR across every eBPF list that carries raw IPs.
    dns_names = _ip_to_fqdn(l7_events)

    # Reverse-DNS the destination IPs (PTR first, observed-DNS fallback) so a
    # connection reads as a hostname, not a bare address.
    await _enrich_addr_fields(top_talkers, "dst_addr", fallback=dns_names)
    # A retransmit can be on an inbound connection too, so enrich BOTH addresses.
    await _enrich_addr_fields(tcp_retransmits, "src_addr", "dst_addr", fallback=dns_names)
    await _enrich_addr_fields(l7_events, "dst_addr", fallback=dns_names)
    return {
        "top_talkers": top_talkers,
        "slowest_disk_io": disk.get("disk_io", []),
        "oom_kills": oom.get("oom_kills", []),
        "tcp_retransmits": tcp_retransmits,
        "signals": sigs.get("signals", []),
        "runq_latency": runq.get("histogram", []),
        "l7_events": l7_events,
    }


# Small process-lifetime cache so repeated eBPF opens don't re-resolve the same
# IPs; PTR records rarely change and a miss is cached too (as None).
_RDNS_CACHE: dict[str, str | None] = {}


async def _rdns(ip: str) -> str | None:
    if ip in _RDNS_CACHE:
        return _RDNS_CACHE[ip]
    host: str | None = None
    try:
        loop = asyncio.get_event_loop()
        name = await asyncio.wait_for(
            loop.run_in_executor(None, lambda: socket.gethostbyaddr(ip)[0]), timeout=1.0
        )
        # Ignore a PTR that just echoes the IP back (no real name).
        host = name if name and name != ip else None
    except Exception:  # noqa: BLE001 — resolution is best-effort
        host = None
    _RDNS_CACHE[ip] = host
    return host


def _ip_to_fqdn(l7_events: list[dict]) -> dict[str, str]:
    """IP→hostname learned from the host's own observed DNS answers (coroot's
    ip_to_fqdn). Resolves targets that have a forward A record but no reverse
    PTR — which best-effort _rdns can never find. First answer wins."""
    out: dict[str, str] = {}
    for e in l7_events:
        if e.get("protocol") == "dns" and e.get("target"):
            for ip in e.get("answers") or []:
                out.setdefault(ip, e["target"])
    return out


async def _enrich_addr_fields(items: list[dict], *fields: str, fallback: dict[str, str] | None = None) -> None:
    """Best-effort reverse-DNS enrichment shared by every eBPF-derived list
    that carries raw IPs (top_talkers has only dst_addr; tcp_retransmits has
    both src_addr and dst_addr since a retransmit can be on an inbound or
    outbound connection). For each address field ("<x>_addr") given, adds a
    sibling "<x>_host" key on the dict when a name is found — a PTR record
    first, then `fallback` (an observed-DNS IP→name map, so forward-only names
    without a PTR still resolve). The UI then shows a hostname instead of a bare
    address wherever one is available."""
    fallback = fallback or {}
    ips = {v for item in items for f in fields if (v := item.get(f))}
    resolved = dict(zip(ips, await asyncio.gather(*(_rdns(ip) for ip in ips))))
    for item in items:
        for f in fields:
            ip = item.get(f)
            host = resolved.get(ip) or fallback.get(ip)
            if host:
                # dst_addr -> dst_host, src_addr -> src_host (NOT dst_addr_host).
                item[f.replace("_addr", "_host") if f.endswith("_addr") else f + "_host"] = host
