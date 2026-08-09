"""Fleet-wide search over the compiled desired_state documents.

One call answers "which hosts have X?" across the whole fleet — config keys/
values, variables, tags, facts, applied checks/roles/thresholds — by scanning
every host's current compiled_host_state (the single living document per host)
and returning the hosts whose document matches, with the matching leaves.

Backs both the UI fleet search and the MCP `fleet_search` tool, so the AI can
analyse the fleet in one step instead of walking hosts one by one.
"""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, CompiledHostState


def _walk(node: Any, prefix: str, out: list[tuple[str, str]]) -> None:
    """Flatten a JSON document to (dotted-path, scalar-string) leaves."""
    if isinstance(node, dict):
        for k, v in node.items():
            _walk(v, f"{prefix}.{k}" if prefix else str(k), out)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _walk(v, f"{prefix}[{i}]", out)
    else:
        out.append((prefix, "" if node is None else str(node)))


def _leaf_matches(path: str, value: str, term: str, kpart: str | None, vpart: str | None) -> bool:
    if kpart is not None:
        # `key=value` form: path must contain kpart AND value contain vpart.
        return kpart in path.lower() and vpart in value.lower()
    hay = f"{path} {value}".lower()
    return term in hay


async def fleet_search(
    session: AsyncSession, query: str, *, per_host: int = 50, host_limit: int = 1000
) -> dict[str, Any]:
    """Search every host's current desired_state for `query`.

    `query` is a plain substring matched against each leaf's "path value", or a
    `key=value` form (path contains key AND value contains value) for precision,
    e.g. `config.*.nginx`, `timezone=Europe`, `os.family=Debian`, `role=web`.

    Returns {query, host_count, hosts: [{host, generation, match_count,
    matches: [{path, value}]}]}. matches is capped per host; match_count is the
    true total so the caller sees when a host was truncated."""
    q = (query or "").strip()
    kpart = vpart = None
    term = q.lower()
    if "=" in q:
        left, _, right = q.partition("=")
        kpart, vpart = left.strip().lower(), right.strip().lower()

    rows = (
        await session.execute(
            select(CompiledHostState, Agent.name)
            .join(Agent, Agent.id == CompiledHostState.agent_id)
            .where(CompiledHostState.is_current.is_(True))
            .limit(host_limit)
        )
    ).all()

    hosts: list[dict[str, Any]] = []
    for state_row, host_name in rows:
        leaves: list[tuple[str, str]] = []
        _walk(state_row.state or {}, "", leaves)
        matched = [(p, v) for (p, v) in leaves if _leaf_matches(p, v, term, kpart, vpart)]
        if not matched:
            continue
        hosts.append({
            "host": host_name,
            "generation": state_row.generation,
            "match_count": len(matched),
            "matches": [{"path": p, "value": v} for p, v in matched[:per_host]],
        })

    hosts.sort(key=lambda h: (-h["match_count"], h["host"]))
    return {"query": q, "host_count": len(hosts), "hosts": hosts}
