"""Security / CVE API (Block 4).

Block 4-B ships the feed status + a manual refresh trigger; the fleet-wide
correlation endpoints (/security/cves, /security/summary) arrive with the
correlator in Block 4-C.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity, require_admin
from bossman.config import Settings, get_settings
from bossman.db.models import Agent, HostCve
from bossman.db.session import get_session
from bossman.services.cve_collect import collect_all_hosts

router = APIRouter()

# Severity ranking for "worst wins" aggregation + summary ordering.
_SEV_RANK = {"critical": 4, "important": 3, "moderate": 2, "low": 1, "": 0}


@router.get("/api/v1/security/feed-status")
async def feed_status(
    request: Request,
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Last CVE-feed refresh outcome + per-distro advisory counts."""
    stats = request.app.state.cve_feed_stats
    return {
        "enabled": settings.cve_feed_enabled,
        "last_run_ok": stats.last_run_ok,
        "last_error": stats.last_error,
        "counts": stats.counts,
    }


@router.post("/api/v1/security/refresh")
async def refresh_feed(
    request: Request,
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_admin),
) -> dict[str, Any]:
    """Force an immediate CVE-feed refresh + a fleet-wide correlation sweep
    (admin only) so the Security page repopulates right away."""
    feed = request.app.state.cve_feed
    await feed.refresh()
    hosts = await collect_all_hosts(request.app.state.session_factory, settings, feed)
    return {
        "ok": request.app.state.cve_feed_stats.last_run_ok,
        "counts": request.app.state.cve_feed_stats.counts,
        "hosts_collected": hosts,
    }


@router.get("/api/v1/security/cves")
async def fleet_cves(
    severity: str | None = Query(None),
    distro: str | None = Query(None),
    agent_id: str | None = Query(None),
    fix_available: bool | None = Query(None),
    q: str | None = Query(None),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Fleet-wide CVEs from correlated pending upgrades, aggregated per CVE with
    the affected hosts. Filterable by severity / distro / host / text / fix."""
    stmt = select(HostCve, Agent.name).join(Agent, Agent.id == HostCve.agent_id)
    if severity:
        stmt = stmt.where(HostCve.severity == severity)
    if distro:
        stmt = stmt.where(HostCve.distro == distro)
    if agent_id:
        stmt = stmt.where(HostCve.agent_id == agent_id)
    if fix_available is True:
        stmt = stmt.where(HostCve.fixed_version != "")
    if q:
        like = f"%{q}%"
        stmt = stmt.where((HostCve.cve.ilike(like)) | (HostCve.package.ilike(like)))
    rows = (await session.execute(stmt)).all()

    by_cve: dict[str, dict[str, Any]] = {}
    for hc, host_name in rows:
        agg = by_cve.setdefault(hc.cve, {"cve": hc.cve, "severity": hc.severity, "distro": hc.distro, "hosts": []})
        if _SEV_RANK.get(hc.severity, 0) > _SEV_RANK.get(agg["severity"], 0):
            agg["severity"] = hc.severity
        agg["hosts"].append({
            "agent_id": str(hc.agent_id), "host": host_name, "package": hc.package,
            "current_version": hc.current_version, "fixed_version": hc.fixed_version,
        })
    out = sorted(by_cve.values(), key=lambda a: (-_SEV_RANK.get(a["severity"], 0), a["cve"]))
    for a in out:
        a["host_count"] = len(a["hosts"])
    return {"count": len(out), "cves": out}


@router.get("/api/v1/security/summary")
async def fleet_summary(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Counts by severity + distro + affected hosts for the Security dashboard."""
    rows = (await session.execute(select(HostCve.severity, HostCve.distro, HostCve.cve, HostCve.agent_id))).all()
    by_sev: dict[str, int] = {}
    by_distro: dict[str, int] = {}
    cves: set[str] = set()
    hosts: set[str] = set()
    for sev, distro, cve, agent_id in rows:
        by_sev[sev or "unknown"] = by_sev.get(sev or "unknown", 0) + 1
        by_distro[distro or "unknown"] = by_distro.get(distro or "unknown", 0) + 1
        cves.add(cve)
        hosts.add(str(agent_id))
    return {
        "total_findings": len(rows),
        "distinct_cves": len(cves),
        "affected_hosts": len(hosts),
        "by_severity": by_sev,
        "by_distro": by_distro,
    }
