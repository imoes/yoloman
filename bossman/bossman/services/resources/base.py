"""Resource / Deployable — the OOP spine (docs/resource-protocol.md).

One small interface every manageable thing implements, so the orchestrator (and
the UI canvas, and the AI) treat every tier the same:

    schema()   -> the typed fields          (renders a form)
    observe()  -> the current state          (shown on the node)
    plan(spec) -> the diff vs desired        (the preview)
    apply(spec, dry_run) -> a Result         (records a generation)
    rollback(generation) -> a Result         (forgiveness)

The STATE stays a serialisable document (nouns); the object is only the
behaviour (verbs). Generations are shared across resource types by the helpers
below, so any tier gets versioned apply + rollback for free — starting with the
docker tier, which had none.
"""
from __future__ import annotations

from typing import Any, Protocol, runtime_checkable

from sqlalchemy import delete as sa_delete, select

from bossman.db.models import ResourceGeneration


@runtime_checkable
class Resource(Protocol):
    """The four-verb contract. resource_key uniquely identifies the instance
    (e.g. "docker:<agent_id>:<name>"); resource_type names the implementation."""

    resource_key: str
    resource_type: str

    def schema(self) -> dict[str, Any]: ...
    async def observe(self) -> dict[str, Any] | None: ...
    async def plan(self, desired: dict[str, Any]) -> dict[str, Any]: ...
    async def apply(self, desired: dict[str, Any], *, dry_run: bool = True,
                    note: str | None = None) -> dict[str, Any]: ...
    async def rollback(self, generation: int) -> dict[str, Any]: ...


def diff_specs(observed: dict[str, Any] | None, desired: dict[str, Any],
               fields: list[str]) -> dict[str, Any]:
    """Field-wise diff → {action, changed:{field:[old,new]}, changed_count}.
    action = create (nothing observed) | update (fields differ) | noop."""
    if observed is None:
        return {"action": "create", "changed": {f: [None, desired.get(f)] for f in fields if desired.get(f) not in (None, "", [], {})},
                "changed_count": 1}
    changed: dict[str, list[Any]] = {}
    for f in fields:
        o, d = observed.get(f), desired.get(f)
        if d is not None and o != d:
            changed[f] = [o, d]
    return {"action": "update" if changed else "noop", "changed": changed, "changed_count": len(changed)}


# --- shared generation store (versioned apply + rollback for any Resource) ----

async def next_generation(session, resource_key: str) -> int:
    rows = (await session.scalars(
        select(ResourceGeneration.generation).where(ResourceGeneration.resource_key == resource_key)
    )).all()
    return (max(rows) + 1) if rows else 1


#: How many generations a resource keeps. The same number the docker desired-state model uses
#: (`services/docker_desired.MAX_GENERATIONS`) — two mechanisms with one meaning should not differ by
#: accident, and the value is here rather than in Settings because a rollback target that changes
#: when someone edits a config file is a rollback target nobody can rely on.
MAX_GENERATIONS = 30


async def _prune_generations(session, resource_key: str) -> int:
    """Drop everything older than the newest MAX_GENERATIONS for this resource. Returns how many.

    Nothing pruned this table until 2026-08-31: every apply added a row and none were ever removed,
    so a resource applied on a cycle grew without bound. The rows are small, which is exactly why it
    stayed unnoticed — and why the fix belongs next to the write rather than in a sweep somewhere
    else, where the two could disagree about which resources are covered.
    """
    keep = (await session.scalars(
        select(ResourceGeneration.generation).where(ResourceGeneration.resource_key == resource_key)
        .order_by(ResourceGeneration.generation.desc()).limit(MAX_GENERATIONS))).all()
    if len(keep) < MAX_GENERATIONS or not keep:
        return 0
    result = await session.execute(sa_delete(ResourceGeneration).where(
        ResourceGeneration.resource_key == resource_key,
        ResourceGeneration.generation < min(keep)))
    return result.rowcount or 0


async def record_generation(session, resource_key: str, resource_type: str, spec: dict[str, Any],
                            *, note: str | None = None, applied_by: str | None = None) -> int:
    gen = await next_generation(session, resource_key)
    session.add(ResourceGeneration(
        resource_key=resource_key, resource_type=resource_type, generation=gen,
        spec=spec, note=note, applied_by=applied_by,
    ))
    # Prune in the SAME transaction as the insert: a crash between the two would either lose the new
    # generation or delete history for one that was never written.
    await _prune_generations(session, resource_key)
    await session.commit()
    return gen


async def list_generations(session, resource_key: str) -> list[dict[str, Any]]:
    rows = (await session.scalars(
        select(ResourceGeneration).where(ResourceGeneration.resource_key == resource_key)
        .order_by(ResourceGeneration.generation.desc())
    )).all()
    return [
        {"generation": r.generation, "spec": r.spec, "note": r.note,
         "applied_by": r.applied_by, "applied_at": r.applied_at.isoformat() if r.applied_at else None}
        for r in rows
    ]


async def no_such_generation(session, resource_key: str, generation: int, name: str) -> dict[str, Any]:
    """The refusal for a rollback target that is not there — and WHY it is not there.

    Since generations are pruned to the newest MAX_GENERATIONS, "not found" has two causes that an
    operator acts on differently: a number that never existed (a typo, or a generation from another
    resource) versus one that existed and was dropped to make room. Answering both with the same
    sentence would make a pruned history indistinguishable from a wrong request — the project's own
    rule is that nothing vanishes silently, and this is where that rule lands for rollback.
    """
    oldest = await session.scalar(
        select(ResourceGeneration.generation).where(ResourceGeneration.resource_key == resource_key)
        .order_by(ResourceGeneration.generation.asc()).limit(1))
    if oldest is not None and generation < oldest:
        return {"ok": False, "error": (
            f"generation {generation} of {name} has been pruned — only the newest {MAX_GENERATIONS} "
            f"are kept and the oldest still held is {oldest}")}
    return {"ok": False, "error": f"no generation {generation} for {name}"}


async def get_generation_spec(session, resource_key: str, generation: int) -> dict[str, Any] | None:
    r = (await session.scalars(
        select(ResourceGeneration).where(
            ResourceGeneration.resource_key == resource_key,
            ResourceGeneration.generation == generation,
        )
    )).first()
    return r.spec if r is not None else None
