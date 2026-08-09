"""Resolve a deployment's target set into a concrete list of agents.

A run/deployment can name its targets in several ways at once — explicit
agent ids, a free-text list of hostnames (paste a list, AWX-style), host
groups, OU subtrees, and tag selectors. This unions them all, de-duplicates
by agent id, and reports any free-text hostname that matched no enrolled
agent (so the caller can surface "3 of 4 hosts found" instead of silently
dropping typos).

Reuses services.compiler.affected_agent_ids for the group/OU subtree
semantics already used by the orchestration link resolver.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent
from bossman.services.compiler import affected_agent_ids


@dataclass
class TargetSpec:
    agent_ids: list[uuid.UUID] = field(default_factory=list)
    hostnames: list[str] = field(default_factory=list)  # free-text list, matched by Agent.name
    group_ids: list[uuid.UUID] = field(default_factory=list)
    ou_ids: list[uuid.UUID] = field(default_factory=list)
    # Tag selectors: {key: value} requires that exact tag; {key: None} requires
    # the tag key to be present with any value.
    tags: dict[str, str | None] = field(default_factory=dict)


@dataclass
class TargetResolution:
    agents: list[Agent]
    unknown_hostnames: list[str]


async def resolve_targets(session: AsyncSession, tenant_id: uuid.UUID, spec: TargetSpec) -> TargetResolution:
    """Union every target selector into a deduplicated agent list (+ the
    free-text hostnames that matched nothing)."""
    ids: set[uuid.UUID] = set(spec.agent_ids)

    for gid in spec.group_ids:
        ids.update(await affected_agent_ids(session, "group", host_group_id=gid, tenant_id=tenant_id))
    for oid in spec.ou_ids:
        ids.update(await affected_agent_ids(session, "ou", ou_id=oid, tenant_id=tenant_id))

    unknown: list[str] = []
    if spec.hostnames:
        wanted = [h.strip() for h in spec.hostnames if h.strip()]
        rows = (
            await session.scalars(
                select(Agent).where(Agent.tenant_id == tenant_id, Agent.name.in_(wanted))
            )
        ).all()
        found_names = {a.name for a in rows}
        ids.update(a.id for a in rows)
        unknown = [h for h in wanted if h not in found_names]

    if spec.tags:
        # JSONB containment for key:value tags; jsonb ? key for presence-only.
        stmt = select(Agent).where(Agent.tenant_id == tenant_id)
        for key, value in spec.tags.items():
            if value is None:
                stmt = stmt.where(Agent.tags.op("?")(key))
            else:
                stmt = stmt.where(Agent.tags.contains({key: value}))
        ids.update(a.id for a in (await session.scalars(stmt)).all())

    if not ids:
        return TargetResolution(agents=[], unknown_hostnames=unknown)

    agents = (
        await session.scalars(select(Agent).where(Agent.tenant_id == tenant_id, Agent.id.in_(ids)))
    ).all()
    return TargetResolution(agents=sorted(agents, key=lambda a: a.name), unknown_hostnames=unknown)
