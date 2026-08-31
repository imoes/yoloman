"""Change-proposal approval queue API (Agentic-OS governance): list AI-proposed
changes, inspect a proposal's dry-run preview, and approve (→apply) or reject.
See services/proposals.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import ChangeProposal
from bossman.db.session import get_session
from bossman.services import proposals as proposals_svc

router = APIRouter()


def _out(p: ChangeProposal, *, full: bool = False) -> dict[str, Any]:
    row = {
        "id": str(p.id), "kind": p.kind, "host": p.host, "title": p.title,
        "requested_by": p.requested_by, "status": p.status,
        "created_at": p.created_at.isoformat(),
        "decided_by": p.decided_by, "decided_at": p.decided_at.isoformat() if p.decided_at else None,
    }
    if full:
        row["payload"] = p.payload or {}
        row["preview"] = p.preview or {}
        row["apply_result"] = p.apply_result or {}
    return row


@router.get("/api/v1/change-proposals")
async def list_proposals(
    status: str | None = None,
    limit: int = 100,
    session: AsyncSession = Depends(get_session),
    _identity: Identity = Depends(get_current_identity),
) -> dict[str, Any]:
    """AI-proposed changes, newest first. `status=pending` for the approval queue."""
    stmt = select(ChangeProposal).order_by(ChangeProposal.created_at.desc()).limit(min(limit, 500))
    if status:
        stmt = stmt.where(ChangeProposal.status == status)
    rows = (await session.scalars(stmt)).all()
    return {"proposals": [_out(p) for p in rows]}


@router.get("/api/v1/change-proposals/{proposal_id}")
async def get_proposal(
    proposal_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity: Identity = Depends(get_current_identity),
) -> dict[str, Any]:
    """One proposal with its full dry-run preview + payload — what a human reviews
    before approving."""
    p = await session.get(ChangeProposal, proposal_id)
    if p is None:
        raise HTTPException(status_code=404, detail="no such proposal")
    return _out(p, full=True)


@router.post("/api/v1/change-proposals/{proposal_id}/approve")
async def approve_proposal(
    proposal_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity: Identity = Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Approve → apply the change for real, recording the outcome + who approved."""
    try:
        p = await proposals_svc.approve(session, settings, client_factory, proposal_id, identity.name)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return _out(p, full=True)


@router.post("/api/v1/change-proposals/{proposal_id}/reject")
async def reject_proposal(
    proposal_id: UUID,
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> dict[str, Any]:
    """Reject a change proposal: it stays as a rejected row and applies to nothing.

    Rejected rather than deleted, on purpose — "someone decided against this" is a fact worth
    keeping, and a proposal that vanished would leave the next person to propose the same fix with no
    idea it had already been refused. The reasoning that produced it stays attached.
    """
    try:
        p = await proposals_svc.reject(session, proposal_id, identity.name)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return _out(p, full=True)
