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

from sqlalchemy import select

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


async def record_generation(session, resource_key: str, resource_type: str, spec: dict[str, Any],
                            *, note: str | None = None, applied_by: str | None = None) -> int:
    gen = await next_generation(session, resource_key)
    session.add(ResourceGeneration(
        resource_key=resource_key, resource_type=resource_type, generation=gen,
        spec=spec, note=note, applied_by=applied_by,
    ))
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


async def get_generation_spec(session, resource_key: str, generation: int) -> dict[str, Any] | None:
    r = (await session.scalars(
        select(ResourceGeneration).where(
            ResourceGeneration.resource_key == resource_key,
            ResourceGeneration.generation == generation,
        )
    )).first()
    return r.spec if r is not None else None
