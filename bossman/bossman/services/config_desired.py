"""Block K4 — a host's effective desired config: the GPO winner per path of its
host-direct resources (HostConfigResource, K3) over the OU-scoped config
policies (ConfigPolicy) on its ancestry. Host-direct always wins; among OU
policies the deepest OU on the host's path wins (closest-to-host, like every
other GPO-resolved thing here). Reused by drift + re-sync so an OU policy
converges every member host — "Host A = Host B"."""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, ConfigPolicy, HostConfigResource
from bossman.services.compiler import resolve_ou_ancestry


def resource_dict(type_: str | None, path: str, fmt: str | None, sep: str | None, values: dict | None, template: str | None) -> dict[str, Any]:
    res: dict[str, Any] = {"type": type_ or "config", "path": path, "values": values or {}}
    if fmt:
        res["format"] = fmt
    if sep:
        res["separator"] = sep
    if template:
        res["template"] = template
    return res


async def effective_resources(session: AsyncSession, agent: Agent) -> list[dict[str, Any]]:
    """[{path, source, resource}] — one per managed path, source 'host' or
    'ou:<path>'. Host-direct wins; else the deepest OU policy on the ancestry."""
    ancestry = await resolve_ou_ancestry(session, agent.ou_id)  # root → leaf
    depth = {n.id: i for i, n in enumerate(ancestry)}
    ou_paths = {n.id: n.path for n in ancestry}

    winner: dict[str, tuple[int, ConfigPolicy, str]] = {}  # path -> (depth, row, source)
    if depth:
        pols = (await session.scalars(select(ConfigPolicy).where(ConfigPolicy.scope_ou_id.in_(list(depth))))).all()
        for p in pols:
            d = depth.get(p.scope_ou_id, -1)
            cur = winner.get(p.path)
            if cur is None or d > cur[0]:
                winner[p.path] = (d, p, "ou:" + ou_paths.get(p.scope_ou_id, str(p.scope_ou_id)))

    merged: dict[str, tuple[dict[str, Any], str]] = {}
    for path, (_, row, source) in winner.items():
        merged[path] = (resource_dict(row.type, row.path, row.config_format, row.separator, row.values, row.template), source)
    # Host-direct overrides any inherited OU policy for the same path.
    for row in (await session.scalars(select(HostConfigResource).where(HostConfigResource.agent_id == agent.id))).all():
        merged[row.path] = (resource_dict(row.type, row.path, row.config_format, row.separator, row.values, row.template), "host")

    return [{"path": path, "source": src, "resource": res} for path, (res, src) in merged.items()]
