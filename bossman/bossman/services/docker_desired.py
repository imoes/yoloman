"""Versioned desired state for a host's containers (project-docker-desired-state).

The docker tier already has observe (docker_app.inspect_containers → portable
specs) and apply (docker_app.deploy_container / remove_container). This adds the
time-machine in between: snapshot the whole container set as a GENERATION (new row
only when the canonical hash changes), diff any two generations, and roll back —
exactly the config-generation model, for containers. Capped at 30 generations.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any
from uuid import UUID

from sqlalchemy import delete as sa_delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import DEFAULT_TENANT_ID, Agent, DockerDesiredState
from bossman.services import docker_app

MAX_GENERATIONS = 30


def _canonical(containers: list[dict[str, Any]]) -> str:
    """Stable JSON of the container set (sorted by name, keys sorted) for hashing —
    so re-discovering an unchanged host produces the same hash and no new row."""
    ordered = sorted(containers, key=lambda c: c.get("name", ""))
    return json.dumps(ordered, sort_keys=True, separators=(",", ":"))


def _hash(containers: list[dict[str, Any]]) -> str:
    return hashlib.sha256(_canonical(containers).encode()).hexdigest()


async def _latest(session: AsyncSession, agent_id: UUID) -> DockerDesiredState | None:
    return await session.scalar(
        select(DockerDesiredState).where(DockerDesiredState.agent_id == agent_id)
        .order_by(DockerDesiredState.generation.desc()).limit(1))


async def _prune(session: AsyncSession, agent_id: UUID) -> None:
    """Keep only the newest MAX_GENERATIONS rows for the host."""
    keep = (await session.scalars(
        select(DockerDesiredState.generation).where(DockerDesiredState.agent_id == agent_id)
        .order_by(DockerDesiredState.generation.desc()).limit(MAX_GENERATIONS))).all()
    if len(keep) >= MAX_GENERATIONS and keep:
        await session.execute(sa_delete(DockerDesiredState).where(
            DockerDesiredState.agent_id == agent_id, DockerDesiredState.generation < min(keep)))


async def _write_generation(session: AsyncSession, agent: Agent, containers: list[dict[str, Any]],
                            compose_files: list[str], *, source: str, note: str | None,
                            created_by: str | None) -> DockerDesiredState:
    latest = await _latest(session, agent.id)
    gen = (latest.generation + 1) if latest else 1
    row = DockerDesiredState(
        tenant_id=DEFAULT_TENANT_ID, agent_id=agent.id, generation=gen,
        spec={"containers": containers, "compose_files": compose_files},
        config_hash=_hash(containers), source=source, note=note, created_by=created_by,
    )
    session.add(row)
    await session.flush()
    await _prune(session, agent.id)
    await session.commit()
    await session.refresh(row)
    return row


async def discover(session: AsyncSession, agent: Agent, client_factory, settings: Settings,
                   created_by: str | None = None) -> dict[str, Any]:
    """Observe the host's containers and snapshot them as a new generation IF the
    canonical spec changed since the last one. Returns {changed, generation, count}."""
    observed = await docker_app.inspect_containers(agent, client_factory, settings)
    containers = observed.get("containers", [])
    compose_files = observed.get("compose_files", [])
    latest = await _latest(session, agent.id)
    if latest is not None and latest.config_hash == _hash(containers):
        return {"changed": False, "generation": latest.generation, "count": len(containers)}
    row = await _write_generation(session, agent, containers, compose_files,
                                  source="discovered", note=None, created_by=created_by)
    return {"changed": True, "generation": row.generation, "count": len(containers)}


async def list_generations(session: AsyncSession, agent_id: UUID) -> list[dict[str, Any]]:
    rows = (await session.scalars(
        select(DockerDesiredState).where(DockerDesiredState.agent_id == agent_id)
        .order_by(DockerDesiredState.generation.desc()))).all()
    return [
        {"generation": r.generation, "count": len((r.spec or {}).get("containers", [])),
         "config_hash": r.config_hash[:12], "source": r.source, "note": r.note,
         "created_by": r.created_by, "created_at": r.created_at.isoformat()}
        for r in rows
    ]


async def _gen_row(session: AsyncSession, agent_id: UUID, generation: int | None) -> DockerDesiredState | None:
    if generation is None:
        return await _latest(session, agent_id)
    return await session.scalar(
        select(DockerDesiredState).where(
            DockerDesiredState.agent_id == agent_id, DockerDesiredState.generation == generation))


async def get_generation(session: AsyncSession, agent_id: UUID, generation: int | None) -> dict[str, Any] | None:
    r = await _gen_row(session, agent_id, generation)
    if r is None:
        return None
    return {"generation": r.generation, "spec": r.spec or {}, "source": r.source,
            "note": r.note, "created_at": r.created_at.isoformat()}


def _by_name(spec: dict[str, Any]) -> dict[str, dict]:
    return {c.get("name", ""): c for c in (spec or {}).get("containers", [])}


async def diff(session: AsyncSession, agent_id: UUID, from_gen: int, to_gen: int) -> dict[str, Any]:
    """Container-level diff between two generations: added / removed / changed
    (with the changed fields), so an operator sees what moved between snapshots."""
    a = await _gen_row(session, agent_id, from_gen)
    b = await _gen_row(session, agent_id, to_gen)
    if a is None or b is None:
        return {"error": "generation not found"}
    old, new = _by_name(a.spec), _by_name(b.spec)
    added = [n for n in new if n not in old]
    removed = [n for n in old if n not in new]
    changed = []
    for n in new:
        if n in old and old[n] != new[n]:
            fields = sorted({k for k in set(old[n]) | set(new[n]) if old[n].get(k) != new[n].get(k)})
            changed.append({"name": n, "fields": fields})
    return {"from": from_gen, "to": to_gen, "added": added, "removed": removed, "changed": changed}


async def rollback(session: AsyncSession, agent: Agent, generation: int, created_by: str) -> dict[str, Any]:
    """Set an OLD generation as the new desired state — writes its spec forward as
    a fresh generation (source=rollback), the same forward-only model config uses.
    Converging the host to it is a separate, explicit apply."""
    target = await _gen_row(session, agent.id, generation)
    if target is None:
        return {"error": "generation not found"}
    spec = target.spec or {}
    row = await _write_generation(
        session, agent, spec.get("containers", []), spec.get("compose_files", []),
        source="rollback", note=f"rollback to generation {generation}", created_by=created_by)
    return {"generation": row.generation, "rolled_back_to": generation}


async def plan_converge(session: AsyncSession, agent: Agent, client_factory, settings: Settings,
                        generation: int | None) -> dict[str, Any]:
    """Compute (without applying) the actions to make the host match a target
    generation: which containers to create, remove, or recreate vs. what is live
    now. The safe preview before an apply."""
    target = await _gen_row(session, agent.id, generation)
    if target is None:
        return {"error": "generation not found"}
    live = await docker_app.inspect_containers(agent, client_factory, settings)
    want = _by_name(target.spec)
    have = {c.get("name", ""): c for c in live.get("containers", [])}
    create = [n for n in want if n not in have]
    remove = [n for n in have if n not in want]
    recreate = [n for n in want if n in have and want[n] != have[n]]
    return {"target_generation": target.generation,
            "create": create, "remove": remove, "recreate": recreate,
            "actions": len(create) + len(remove) + len(recreate)}
