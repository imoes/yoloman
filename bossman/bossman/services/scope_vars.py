"""Resolve a host's variables from ScopeVars (Block G11) — GPO-style, the
same precedence as check thresholds: a value on an OU is inherited by its
hosts and overridable per group and per host.

weakest → strongest:  group  <  OU (root → leaf)  <  host

The result is merged into a runbook run's variables (below the explicit
request variables, above the agent facts). Pure read; reuses the
orchestration compiler's ancestry + group-membership resolvers.
"""

from __future__ import annotations

from typing import Any

from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, ScopeVars
from bossman.services import gpo
from bossman.services.compiler import resolve_host_group_ids, resolve_ou_ancestry


async def resolve_scope_vars(session: AsyncSession, agent: Agent) -> dict[str, Any]:
    """The GPO-merged variables for `agent` from every ScopeVars row that
    reaches it (host-direct + its groups + its OU ancestry)."""
    ancestry = await resolve_ou_ancestry(session, agent.ou_id)
    ancestry_depth = {n.id: depth for depth, n in enumerate(ancestry)}
    group_ids = await resolve_host_group_ids(session, agent.id)

    clauses = [and_(ScopeVars.scope_type == "host", ScopeVars.agent_id == agent.id)]
    if group_ids:
        clauses.append(and_(ScopeVars.scope_type == "group", ScopeVars.host_group_id.in_(group_ids)))
    if ancestry_depth:
        clauses.append(and_(ScopeVars.scope_type == "ou", ScopeVars.ou_id.in_(list(ancestry_depth))))

    rows = (
        await session.scalars(
            select(ScopeVars).where(ScopeVars.tenant_id == agent.tenant_id, or_(*clauses))
        )
    ).all()

    def level(r: ScopeVars) -> int:
        if r.scope_type == "host":
            return gpo.LEVEL_HOST
        if r.scope_type == "group":
            return gpo.LEVEL_GROUP
        return gpo.LEVEL_OU_BASE + ancestry_depth.get(r.ou_id, 0)

    merged: dict[str, Any] = {}
    for r in sorted(rows, key=level):  # weakest → strongest
        merged.update(r.vars or {})
    return merged
