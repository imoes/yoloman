"""GET /api/v1/topology/graph — the infrastructure map (CentralStation-style):
hosts as nodes, the eBPF-derived relationships (host_edges, aggregated from
every agent's connection dump) as edges, plus proxy→satellite parent edges.

The assembled graph is cached briefly (TTL) so the map is cheap to poll and to
paint; `?refresh=true` bypasses the cache. Node status comes from the same
CheckMK-style state rollup the fleet overview uses.
"""

from __future__ import annotations

import ipaddress
import logging
import time
from typing import Any

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import HostEdge
from bossman.db.session import get_session
from bossman.services.monitoring import fleet_hosts

logger = logging.getLogger(__name__)

router = APIRouter()

# CentralStation severity vocabulary — the frontend colors nodes by it.
_STATE_TO_SEV = {"CRIT": "critical", "WARN": "medium", "OK": "ok", "UNKNOWN": "low"}

_CACHE_TTL_S = 15.0
_cache: dict[str, Any] = {"at": 0.0, "graph": None}

# Well-known service ports → a human label, so an external node reads
# "192.0.2.98 · Kerberos, LDAP" instead of a bare IP (F-3). Only ports we can
# name meaningfully; anything else is shown by number on the edge.
_PORT_SERVICE = {
    22: "SSH", 25: "SMTP", 53: "DNS", 80: "HTTP", 88: "Kerberos", 110: "POP3",
    123: "NTP", 143: "IMAP", 389: "LDAP", 443: "HTTPS", 445: "SMB", 465: "SMTPS",
    514: "syslog", 587: "SMTP", 636: "LDAPS", 993: "IMAPS", 995: "POP3S",
    1433: "MSSQL", 3306: "MySQL", 3389: "RDP", 5432: "PostgreSQL", 5672: "AMQP",
    6379: "Redis", 8006: "Proxmox", 9092: "Kafka", 9200: "Elasticsearch",
    11211: "memcached", 27017: "MongoDB",
}

# Cap external destinations drawn on the map (busiest first) so a chatty host
# doesn't produce hundreds of nodes; the count dropped is logged, never silent.
_MAX_EXTERNAL_NODES = 40


def _is_loopback(addr: str) -> bool:
    try:
        return ipaddress.ip_address(addr).is_loopback
    except ValueError:
        return False


def _service_hint(ports: set[int]) -> str:
    names = [_PORT_SERVICE[p] for p in sorted(ports) if p in _PORT_SERVICE]
    # de-dupe while preserving order (587 and 25 both map to SMTP)
    seen: list[str] = []
    for n in names:
        if n not in seen:
            seen.append(n)
    return ", ".join(seen[:3]) + ("…" if len(seen) > 3 else "")


@router.get("/api/v1/topology/graph")
async def topology_graph(
    refresh: bool = Query(False, description="Bypass the short-lived cache and rebuild"),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    now = time.monotonic()
    if not refresh and _cache["graph"] is not None and (now - _cache["at"]) < _CACHE_TTL_S:
        return _cache["graph"]

    hosts = await fleet_hosts(session)
    nodes: list[dict[str, Any]] = []
    known: set[str] = set()
    alerts = 0
    for h in hosts:
        counts = h.service_counts or {}
        alert_count = int(counts.get("CRIT", 0)) + int(counts.get("WARN", 0))
        alerts += int(counts.get("CRIT", 0))
        nodes.append({
            "id": str(h.id),
            "label": h.name,
            "type": "proxy" if h.mode == "proxy" else "host",
            "status": _STATE_TO_SEV.get(h.state_rollup, "low"),
            "alert_count": alert_count,
            "inactive": h.enrollment_state != "enrolled",
        })
        known.add(str(h.id))

    edges: list[dict[str, Any]] = []
    # Proxy → satellite parentage (structural edges).
    for h in hosts:
        if h.parent_agent_id and str(h.parent_agent_id) in known:
            edges.append({"source": str(h.parent_agent_id), "target": str(h.id), "kind": "parent"})

    # eBPF connection edges (host_edges), aggregated per (src,dst) agent pair.
    rows = (await session.scalars(select(HostEdge).where(HostEdge.dst_agent_id.isnot(None)))).all()
    seen_pairs: dict[tuple[str, str], dict[str, Any]] = {}
    for e in rows:
        src, dst = str(e.src_agent_id), str(e.dst_agent_id)
        if src == dst or src not in known or dst not in known:
            continue
        key = (src, dst)
        agg = seen_pairs.get(key)
        if agg is None:
            agg = {"source": src, "target": dst, "kind": "connection", "ports": set(),
                   "events": 0, "_lat_w": 0.0, "_lat_ev": 0, "p99": None}
            seen_pairs[key] = agg
        agg["ports"].add(e.dst_port)
        ev = int(e.event_count or 0)
        agg["events"] += ev
        # Events-weighted mean of per-edge p50 latency (Coroot-style edge RED);
        # p99 is the worst across the aggregated edges.
        if e.latency_ms_p50 is not None and ev > 0:
            agg["_lat_w"] += float(e.latency_ms_p50) * ev
            agg["_lat_ev"] += ev
        if e.latency_ms_p99 is not None:
            agg["p99"] = e.latency_ms_p99 if agg["p99"] is None else max(agg["p99"], e.latency_ms_p99)
    for agg in seen_pairs.values():
        ports = sorted(agg.pop("ports"))
        agg["label"] = ",".join(str(p) for p in ports[:4]) + ("…" if len(ports) > 4 else "")
        lat_ev = agg.pop("_lat_ev")
        lat_w = agg.pop("_lat_w")
        agg["latency_ms"] = round(lat_w / lat_ev, 2) if lat_ev > 0 else None
        # Edge health from latency (no SLO yet): >200ms warn, >1s crit.
        lat = agg["latency_ms"]
        agg["status"] = "crit" if (lat is not None and lat > 1000) else "warn" if (lat is not None and lat > 200) else "ok"
        edges.append(agg)

    # External destinations (F-3): connections to things that aren't enrolled
    # agents — LDAP/Kerberos DCs, mail relays, upstream HTTP — are the bulk of
    # a real host's edges, and dropping them left the map showing "0 edges".
    # Synthesise one node per external IP (loopback excluded), with an edge
    # from each talking agent, aggregating ports/events/latency like the
    # internal edges. Group by IP so a DC offering LDAP+Kerberos is one node.
    ext_rows = (await session.scalars(select(HostEdge).where(HostEdge.dst_agent_id.is_(None)))).all()
    ext_pairs: dict[tuple[str, str], dict[str, Any]] = {}
    ext_totals: dict[str, int] = {}
    for e in ext_rows:
        src = str(e.src_agent_id)
        if src not in known:
            continue
        addr = str(e.dst_addr)
        if _is_loopback(addr):
            continue
        ext_totals[addr] = ext_totals.get(addr, 0) + int(e.event_count or 0)
        key = (src, addr)
        agg = ext_pairs.get(key)
        if agg is None:
            agg = {"source": src, "target": "ext:" + addr, "_addr": addr, "kind": "connection",
                   "ports": set(), "events": 0, "_lat_w": 0.0, "_lat_ev": 0, "p99": None}
            ext_pairs[key] = agg
        agg["ports"].add(e.dst_port)
        ev = int(e.event_count or 0)
        agg["events"] += ev
        if e.latency_ms_p50 is not None and ev > 0:
            agg["_lat_w"] += float(e.latency_ms_p50) * ev
            agg["_lat_ev"] += ev
        if e.latency_ms_p99 is not None:
            agg["p99"] = e.latency_ms_p99 if agg["p99"] is None else max(agg["p99"], e.latency_ms_p99)

    # Keep the busiest external hosts; a chatty box shouldn't drown the graph.
    kept_addrs = sorted(ext_totals, key=lambda a: ext_totals[a], reverse=True)[:_MAX_EXTERNAL_NODES]
    dropped = len(ext_totals) - len(kept_addrs)
    if dropped > 0:
        logger.info("topology: showing top %d external destinations, %d less-active ones omitted",
                    len(kept_addrs), dropped)
    kept = set(kept_addrs)
    ext_ports: dict[str, set[int]] = {}
    for agg in ext_pairs.values():
        if agg["_addr"] not in kept:
            continue
        ext_ports.setdefault(agg["_addr"], set()).update(agg["ports"])
        ports = sorted(agg.pop("ports"))
        agg["label"] = ",".join(str(p) for p in ports[:4]) + ("…" if len(ports) > 4 else "")
        lat_ev = agg.pop("_lat_ev")
        lat_w = agg.pop("_lat_w")
        agg.pop("_addr")
        agg["latency_ms"] = round(lat_w / lat_ev, 2) if lat_ev > 0 else None
        lat = agg["latency_ms"]
        agg["status"] = "crit" if (lat is not None and lat > 1000) else "warn" if (lat is not None and lat > 200) else "ok"
        edges.append(agg)
    for addr in kept_addrs:
        hint = _service_hint(ext_ports.get(addr, set()))
        nodes.append({
            "id": "ext:" + addr,
            "label": f"{addr} · {hint}" if hint else addr,
            "type": "external",
            "status": "ok",
            "alert_count": 0,
            "inactive": False,
        })

    graph = {
        "nodes": nodes,
        "edges": edges,
        "stats": {"hosts": len(nodes), "edges": len(edges), "alerts": alerts},
        "error": "" if nodes else "No hosts enrolled yet.",
        "generated_at": None,
    }
    _cache["graph"] = graph
    _cache["at"] = now
    return graph
