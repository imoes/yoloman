"""The server-document endpoint (killer-feature increment d) — the AI knowledge
substrate. GET the whole host as one JSON (config + desired + generations +
topology) so the assistant/MCP can reason with complete, fresh context. See
services/server_document.py. Read-only; the desired-state UI is unchanged."""
from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import require_manage_agent
from bossman.api.management import _agent_with_address
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services.blast_radius import compute_blast_radius
from bossman.services.chat_client import chat_client_for
from bossman.services.server_document import ALL_SECTIONS, build_server_document
from bossman.services.server_narrative import explain_server

router = APIRouter()


class ExplainBody(BaseModel):
    question: str | None = None


class BlastRadiusBody(BaseModel):
    resources: list[dict[str, Any]] = []


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


@router.post("/api/v1/agents/{agent_id}/explain")
async def explain_agent(
    agent_id: UUID,
    body: ExplainBody | None = None,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Self-documenting infra: the LLM documents this server (no question) or
    answers a question, grounded strictly in its live state document. The
    answer cannot go stale — it's generated from the live desired+observed
    state each time."""
    agent = await _agent_with_address(session, agent_id)
    return await explain_server(
        session, agent, client_factory, settings,
        chat=chat_client_for(settings), question=(body.question if body else None),
    )


@router.post("/api/v1/agents/{agent_id}/blast-radius")
async def agent_blast_radius(
    agent_id: UUID,
    body: BlastRadiusBody,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """What-if guardrail: predict the effect of applying `resources` — the change
    diff (state/plan) + the inbound dependents that could be affected — WITHOUT
    writing. Call before apply."""
    agent = await _agent_with_address(session, agent_id)
    return await compute_blast_radius(session, agent, client_factory, settings, body.resources)
