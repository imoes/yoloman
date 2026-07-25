"""The server-document endpoint (killer-feature increment d) — the AI knowledge
substrate. GET the whole host as one JSON (config + desired + generations +
topology) so the assistant/MCP can reason with complete, fresh context. See
services/server_document.py. Read-only; the desired-state UI is unchanged."""
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
from bossman.services.server_document import ALL_SECTIONS, build_server_document

router = APIRouter()


@router.get("/api/v1/agents/{agent_id}/document")
async def get_agent_document(
    agent_id: UUID,
    include: str = Query(
        ",".join(ALL_SECTIONS),
        description="Comma-separated sections: config,desired,generations,topology.",
    ),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """The complete server-document for one host — the AI's full-context read."""
    agent = await _agent_with_address(session, agent_id)
    inc = {p.strip() for p in include.split(",") if p.strip()} or set(ALL_SECTIONS)
    return await build_server_document(session, agent, client_factory, settings, inc)
