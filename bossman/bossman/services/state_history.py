"""Time machine over a host's desired_state generations.

Bossman writes a new compiled_host_state generation whenever a host's desired
document changes (services/compiler). This lists that history and diffs any two
generations leaf-by-leaf — "what changed between gen N and M" — so an operator
(or the AI) can see exactly which config/variable/threshold/role value moved and
when. Pure read.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import CompiledHostState


def _flatten(node: Any, prefix: str, out: dict[str, str]) -> None:
    if isinstance(node, dict):
        for k, v in node.items():
            _flatten(v, f"{prefix}.{k}" if prefix else str(k), out)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _flatten(v, f"{prefix}[{i}]", out)
    else:
        out[prefix] = "" if node is None else str(node)


async def list_generations(session: AsyncSession, agent_id: UUID) -> list[dict[str, Any]]:
    """Every stored desired-state generation for the host, newest first."""
    rows = (
        await session.scalars(
            select(CompiledHostState)
            .where(CompiledHostState.agent_id == agent_id)
            .order_by(CompiledHostState.generation.desc())
        )
    ).all()
    return [
        {
            "generation": r.generation,
            "config_hash": r.config_hash,
            "is_current": r.is_current,
            "compiled_at": r.compiled_at.isoformat() if r.compiled_at else None,
        }
        for r in rows
    ]


async def _state_of(session: AsyncSession, agent_id: UUID, generation: int | None) -> tuple[int | None, dict]:
    """The state doc of one generation (or the current one if generation is None)."""
    stmt = select(CompiledHostState).where(CompiledHostState.agent_id == agent_id)
    stmt = stmt.where(CompiledHostState.generation == generation) if generation is not None \
        else stmt.where(CompiledHostState.is_current.is_(True))
    row = await session.scalar(stmt)
    return (row.generation, row.state or {}) if row else (None, {})


async def diff_generations(
    session: AsyncSession, agent_id: UUID, from_gen: int | None, to_gen: int | None
) -> dict[str, Any]:
    """Leaf-level diff between two generations (default: previous → current).
    Returns {from, to, added, removed, changed} where each entry carries the
    dotted path and value(s)."""
    to_g, to_state = await _state_of(session, agent_id, to_gen)
    if from_gen is None and to_g is not None:
        from_gen = to_g - 1 if to_g > 1 else None
    from_g, from_state = await _state_of(session, agent_id, from_gen)

    a: dict[str, str] = {}
    b: dict[str, str] = {}
    _flatten(from_state, "", a)
    _flatten(to_state, "", b)

    added = [{"path": p, "value": b[p]} for p in b.keys() - a.keys()]
    removed = [{"path": p, "value": a[p]} for p in a.keys() - b.keys()]
    changed = [{"path": p, "old": a[p], "new": b[p]} for p in a.keys() & b.keys() if a[p] != b[p]]
    for lst in (added, removed):
        lst.sort(key=lambda x: x["path"])
    changed.sort(key=lambda x: x["path"])
    return {
        "from": from_g, "to": to_g,
        "added": added, "removed": removed, "changed": changed,
        "change_count": len(added) + len(removed) + len(changed),
    }
