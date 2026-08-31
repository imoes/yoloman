"""Capability matcher REST — the Lego editor's / AI's read surface over host_capabilities.

One deterministic logic (services/capabilities.py), three interfaces; this is the HTTP one:
  GET /api/v1/agents/{id}/capabilities        what this host provides + requires
  GET /api/v1/capabilities/providers          who provides capability[:backend] (editor's suggestion list)
  GET /api/v1/capabilities/match?agent_id=     for a host's open requirements: matching providers, the
                                               roles a NEW server would need, and a proposed wiring per hit
"""
from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.models import Agent, HostCapability
from bossman.db.session import get_session
from bossman.services import capabilities as C
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

router = APIRouter()


@router.get("/api/v1/agents/{agent_id}/capabilities")
async def host_capabilities(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """What this host **provides** and what it **requires** — the lego model's two halves.

    Derived from what is installed and configured rather than declared by hand, so it answers "what
    could use this host" without anyone maintaining a list — and it goes stale exactly as fast as the
    host's inventory does, which the timestamp tells you.
    """
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="agent not found")
    rows = list(await session.scalars(
        select(HostCapability).where(HostCapability.agent_id == agent_id)))

    def _dump(r: HostCapability) -> dict:
        return {"capability": r.capability, "backend": r.backend, "template": r.template,
                "source": r.source, "port": r.port, "config_path": r.config_path, "detail": r.detail}

    return {
        "agent_id": str(agent_id),
        "provides": [_dump(r) for r in rows if r.kind == "provide"],
        "requires": [_dump(r) for r in rows if r.kind == "require"],
    }


@router.get("/api/v1/capabilities/providers")
async def providers(
    capability: str = Query(...),
    backend: str = Query("", description="restrict to a backend the consumer accepts (alias-aware)"),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Who provides a capability, fleet-wide: one row per host that can satisfy it.

    The answer to "where can this run" before anything is placed. An empty result is a real answer,
    not an error.
    """
    hosts = await C.find_providers(session, settings, capability, [backend] if backend else [])
    roles = C.roles_providing(settings, capability, backend or None)
    return {"capability": capability, "backend": backend or None, "providers": hosts, "roles": roles}


@router.get("/api/v1/capabilities/match")
async def match(
    agent_id: UUID = Query(..., description="the consumer host whose open requirements to satisfy"),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Match requirements against providers and say **why** each candidate fits or does not.

    The reason is the point: a matcher that returned only winners could not be argued with, and a
    placement decision has to be explainable to whoever is paged about it later.
    """
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="agent not found")
    consumer_addr = C._agent_address(agent)
    reqs = await C.open_requirements(session, agent_id)
    out: list[dict] = []
    for req in reqs:
        detail = req.detail or {}
        backends = detail.get("backends") or ([req.backend] if req.backend else [])
        found = await C.find_providers(session, settings, req.capability, backends,
                                       tenant_id=agent.tenant_id, exclude_agent=agent_id)
        matches = [{"provider": p, "wiring": C.propose_wiring(detail, p, consumer_address=consumer_addr)}
                   for p in found]
        entry: dict[str, Any] = {
            "capability": req.capability, "backends": backends, "template": req.template,
            "fields": detail.get("fields") or {}, "matches": matches,
        }
        if not found:   # nothing in the inventory provides it → which role a NEW server would need
            entry["candidate_roles"] = C.roles_providing(settings, req.capability,
                                                          backends[0] if backends else None)
        out.append(entry)
    return {"agent_id": str(agent_id), "requirements": out}
