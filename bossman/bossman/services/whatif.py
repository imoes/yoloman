"""What-if blast radius: which hosts a policy WOULD hit, before you create it.

Given a scope (OU/group/site/host/global) and optional Checkmk conditions, this
resolves the hosts the scope reaches and then keeps only those whose live match
context satisfies the conditions — the exact set a config policy / threshold /
check assignment authored that way would apply to. Pure read, nothing persisted,
so it backs a "Matches N of M hosts" preview in the editors and an MCP tool the
AI can call before proposing a change.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent
from bossman.services import rule_conditions
from bossman.services.check_assignments import build_match_context
from bossman.services.compiler import affected_agent_ids

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


async def whatif_scope(
    session: AsyncSession,
    scope_type: str,
    *,
    ou_id: UUID | None = None,
    host_group_id: UUID | None = None,
    site_id: UUID | None = None,
    agent_id: UUID | None = None,
    conditions: dict | None = None,
    limit: int = 500,
) -> dict[str, Any]:
    """Return {total_in_scope, matched_count, matched, excluded} — the hosts a
    policy at this scope with these conditions would (and wouldn't) apply to."""
    ids = await affected_agent_ids(
        session, scope_type, ou_id=ou_id, host_group_id=host_group_id,
        site_id=site_id, agent_id=agent_id, tenant_id=DEFAULT_TENANT_ID,
    )
    total = len(ids)
    if not ids:
        return {"total_in_scope": 0, "matched_count": 0, "matched": [], "excluded": []}

    agents = (await session.scalars(select(Agent).where(Agent.id.in_(list(ids))))).all()
    conds = conditions or {}
    matched: list[str] = []
    excluded: list[str] = []
    for a in agents:
        if not conds:
            matched.append(a.name)
            continue
        ctx = await build_match_context(session, a)
        (matched if rule_conditions.matches(conds, ctx) else excluded).append(a.name)

    matched.sort()
    excluded.sort()
    return {
        "total_in_scope": total,
        "matched_count": len(matched),
        "matched": matched[:limit],
        "excluded": excluded[:limit],
    }
