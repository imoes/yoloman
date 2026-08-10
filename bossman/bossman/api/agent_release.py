"""Agent update channel API — is there a newer yoloman-agent package on GitHub,
which enrolled hosts are behind, and a one-click rollout that verifies the
package hash before pushing the self-update.

GET  /api/v1/agent-release           cached latest release (version + per-asset
                                     sha256 + checked_at) plus the outdated hosts
POST /api/v1/agent-release/check     force a re-check of the release channel now
POST /api/v1/agent-release/rollout   push the verified package to given/outdated
                                     hosts over the existing mTLS self-update path
"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import require_admin
from bossman.api.package_wizard import _family
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent
from bossman.db.session import get_session
from bossman.services import agent_release
from bossman.services.agent_client import AgentClientError

router = APIRouter()


def _kind_for(agent: Agent) -> str:
    return "rpm" if _family(agent.facts or {}) in ("redhat", "suse") else "deb"


async def _outdated(session: AsyncSession, latest_version: str) -> list[dict]:
    """Enrolled agents whose reported version is older than the latest release."""
    rows = (await session.execute(
        select(Agent).where(Agent.enrollment_state == "enrolled")
    )).scalars().all()
    out = []
    for a in rows:
        if agent_release.is_newer(latest_version, a.agent_version or ""):
            out.append({
                "id": str(a.id),
                "name": a.name,
                "agent_version": a.agent_version or "",
                "address": a.address or "",
                "kind": _kind_for(a),
                "updatable": bool(a.address),  # no direct address → can't push directly
            })
    return out


@router.get("/api/v1/agent-release")
async def get_agent_release(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(require_admin),
) -> dict:
    """The cached release view + which enrolled hosts are behind it. No network
    call here (the poller refreshes the cache); use POST /check to force one."""
    snap = agent_release.snapshot()
    latest = snap.get("latest")
    snap["outdated"] = await _outdated(session, latest["version"]) if latest else []
    return snap


@router.post("/api/v1/agent-release/check")
async def check_agent_release(
    settings: Settings = Depends(get_settings),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(require_admin),
) -> dict:
    """Force a re-check of the GitHub release channel now, then return the fresh
    view (same shape as GET)."""
    await agent_release.refresh(settings)
    snap = agent_release.snapshot()
    latest = snap.get("latest")
    snap["outdated"] = await _outdated(session, latest["version"]) if latest else []
    return snap


class RolloutRequest(BaseModel):
    """Target selection. Either an explicit list of agent ids, or all_outdated to
    push to every enrolled host currently behind the latest release."""
    agent_ids: list[UUID] = []
    all_outdated: bool = False


@router.post("/api/v1/agent-release/rollout")
async def rollout_agent_release(
    body: RolloutRequest,
    settings: Settings = Depends(get_settings),
    session: AsyncSession = Depends(get_session),
    client_factory=Depends(get_client_factory),
    _identity=Depends(require_admin),
) -> dict:
    """Download the latest package (per host OS family), VERIFY its sha256 against
    the release manifest, and push it to each target over the mTLS self-update
    channel. The verified bytes are cached per kind so a fleet rollout downloads
    each package at most once."""
    snap = agent_release.snapshot()
    latest = snap.get("latest")
    if not latest:
        raise HTTPException(status_code=409, detail="no release info yet — run a check first")

    # Resolve targets.
    if body.all_outdated:
        target_ids = {UUID(o["id"]) for o in await _outdated(session, latest["version"])}
    else:
        target_ids = set(body.agent_ids)
    if not target_ids:
        raise HTTPException(status_code=422, detail="no targets — pass agent_ids or all_outdated=true")

    agents = (await session.execute(select(Agent).where(Agent.id.in_(target_ids)))).scalars().all()
    if not agents:
        raise HTTPException(status_code=404, detail="no matching agents")

    verified: dict[str, bytes] = {}  # kind → bytes (download+verify once per kind)
    results = []
    for agent in agents:
        entry: dict = {"agent_id": str(agent.id), "name": agent.name}
        if not agent.address:
            entry.update(ok=False, error="no direct address — cannot push (satellite/unenrolled)")
            results.append(entry)
            continue
        kind = _kind_for(agent)
        try:
            if kind not in verified:
                data, asset = await agent_release.download_verified(settings, kind)
                verified[kind] = data
                entry["asset"] = asset.name
            result = await client_factory(agent, settings).self_update(verified[kind])
            entry.update(ok=True, kind=kind, result=result)
        except (AgentClientError, RuntimeError) as exc:
            entry.update(ok=False, error=str(exc)[:300])
        results.append(entry)

    return {"version": latest["version"], "pushed": sum(1 for r in results if r.get("ok")), "results": results}
