"""Systems API (test-systems Block 1, read-only half) — propose a `System` (the
unit above a host: apps + wiring) from a seed host's live state. Persistence
(System/SystemMember tables + POST/GET by id) is a follow-up slice once the
shape is validated. See docs/test-systems.md."""
from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import require_manage_agent
from bossman.api.management import _agent_with_address
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services import system_discover

router = APIRouter()


@router.get("/api/v1/systems/propose")
async def propose_system(
    agent_id: UUID = Query(..., description="seed host to propose a System from"),
    name: str | None = Query(None),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Propose (not persist) a System from a seed host: its apps across docker /
    k8s / native + compose-derived wiring. The read-only foundation for
    clone-a-prod-system."""
    agent = await _agent_with_address(session, agent_id)
    return await system_discover.propose_system(session, agent, client_factory, settings, name=name)
