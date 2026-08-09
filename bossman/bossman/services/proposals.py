"""Change-proposal approval queue — the human-in-the-loop gate for autonomous
(AI-decided) changes (Agentic-OS governance).

When the AI decides to APPLY a change and the fleet isn't in YOLO mode, it files
a ChangeProposal carrying the dry-run PREVIEW instead of applying. A human then
approves (→ apply, recorded to the audit trail) or rejects. This mirrors the L2
orchestration-link approval for policy, but for direct config/runbook applies.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import DEFAULT_TENANT_ID, Agent, ChangeProposal
from bossman.services.audit import record_audit


async def create_config_proposal(
    session: AsyncSession, agent: Agent, resources: list[dict[str, Any]],
    preview: dict[str, Any], requested_by: str | None, title: str = "",
) -> ChangeProposal:
    """File a pending config-apply proposal with its dry-run preview."""
    p = ChangeProposal(
        tenant_id=DEFAULT_TENANT_ID, kind="config", agent_id=agent.id, host=agent.name,
        title=title or f"Config change on {agent.name}",
        payload={"resources": resources}, preview=preview or {},
        requested_by=requested_by, status="pending",
    )
    session.add(p)
    await session.commit()
    await session.refresh(p)
    await record_audit(
        session, actor=requested_by or "unknown",
        actor_kind="external" if (requested_by or "").startswith("ai:") else None,
        action="proposal.create", category="config", target=f"{agent.name}",
        detail={"proposal_id": str(p.id), "kind": "config", "title": p.title},
    )
    return p


async def approve(
    session: AsyncSession, settings: Settings, client_factory, proposal_id: UUID, decided_by: str,
) -> ChangeProposal:
    """Approve → apply for real. Reuses the same document-loop apply path the
    dry-run previewed, records the outcome, and audits who approved it."""
    p = await session.get(ChangeProposal, proposal_id)
    if p is None:
        raise ValueError("no such proposal")
    if p.status != "pending":
        raise ValueError(f"proposal is {p.status}, not pending")
    agent = await session.get(Agent, p.agent_id) if p.agent_id else None
    if agent is None:
        raise ValueError("the proposal's host no longer exists")

    result: dict[str, Any] = {}
    status = "applied"
    try:
        if p.kind == "config":
            client = client_factory(agent, settings)
            result = await client.state_apply({"resources": p.payload.get("resources", [])}, False)
        else:
            raise ValueError(f"unsupported proposal kind {p.kind!r}")
    except Exception as exc:  # noqa: BLE001 — a failed apply is a recorded outcome, not a 500
        status = "failed"
        result = {"error": str(exc)}

    p.status = status
    p.apply_result = result
    p.decided_by = decided_by
    p.decided_at = datetime.now(timezone.utc)
    await session.commit()
    await record_audit(
        session, actor=decided_by, action="proposal.approve", category="config",
        target=p.host, status="ok" if status == "applied" else "failed",
        detail={"proposal_id": str(p.id), "kind": p.kind, "result_status": status},
    )
    await session.refresh(p)
    return p


async def reject(session: AsyncSession, proposal_id: UUID, decided_by: str) -> ChangeProposal:
    p = await session.get(ChangeProposal, proposal_id)
    if p is None:
        raise ValueError("no such proposal")
    if p.status != "pending":
        raise ValueError(f"proposal is {p.status}, not pending")
    p.status = "rejected"
    p.decided_by = decided_by
    p.decided_at = datetime.now(timezone.utc)
    await session.commit()
    await record_audit(
        session, actor=decided_by, action="proposal.reject", category="config",
        target=p.host, detail={"proposal_id": str(p.id), "kind": p.kind},
    )
    await session.refresh(p)
    return p
