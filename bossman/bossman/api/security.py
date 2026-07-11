"""Security / CVE API (Block 4).

Block 4-B ships the feed status + a manual refresh trigger; the fleet-wide
correlation endpoints (/security/cves, /security/summary) arrive with the
correlator in Block 4-C.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Request

from bossman.api.auth import get_current_identity, require_admin
from bossman.config import Settings, get_settings

router = APIRouter()


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
async def refresh_feed(request: Request, _identity=Depends(require_admin)) -> dict[str, Any]:
    """Force an immediate CVE-feed refresh (admin only)."""
    feed = request.app.state.cve_feed
    await feed.refresh()
    return {"ok": request.app.state.cve_feed_stats.last_run_ok, "counts": request.app.state.cve_feed_stats.counts}
