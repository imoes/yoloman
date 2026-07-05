"""Plan-catalog RAG: embedding-based retrieval over the plan catalog (see
docs/plan.md's "Plan-catalog RAG"), for use once the catalog grows past a
handful of plans — dumping every plan's description into the (cached) MCP
system prompt stops scaling long before that. `catalog_markdown` (see
services/catalog.py) is unaffected and remains the default for the current
small catalog; search_plans is an additional option, not a replacement.

Mirrors services/chunk_similarity.py's shape (exact-hash short-circuit,
cosine similarity search) but batches the indexing step: a plan catalog is
typically re-embedded all at once (on search, or on an explicit reindex),
not one plan at a time, so index_plan_catalog embeds every changed plan in
a single request rather than looping index_chunk-style per plan.
"""

from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import PlanEmbedding
from bossman.services.embedding_client import EmbeddingClient
from bossman.services.plan_loader import Plan, hash_source_text


def _embed_text(plan: Plan) -> str:
    """The text embedded for one plan — name plus its own author-written
    description, the same "what is this plan for" content already surfaced
    in render_catalog_markdown, just embedded instead of dumped in full."""
    return f"{plan.name}: {plan.description}"


@dataclass
class SimilarPlan:
    name: str
    description: str
    similarity: float


async def index_plan_catalog(session: AsyncSession, embedding_client: EmbeddingClient, plans: list[Plan]) -> int:
    """Upserts an embedding row for every plan whose description has
    changed since it was last indexed (by content_hash) — the batch
    analogue of chunk_similarity.index_chunk's single-item short-circuit.
    Every changed plan is embedded in one batched embed() call, not N
    sequential ones. Returns how many were actually (re-)embedded; 0 means
    every plan's embedding was already current (the cache hit this
    function exists for)."""
    existing_hashes: dict[str, str] = dict(
        (await session.execute(select(PlanEmbedding.name, PlanEmbedding.content_hash))).all()
    )

    stale = [p for p in plans if existing_hashes.get(p.name) != hash_source_text(_embed_text(p))]
    if not stale:
        return 0

    vectors = await embedding_client.embed([_embed_text(p) for p in stale])
    for plan, vector in zip(stale, vectors, strict=True):
        stmt = insert(PlanEmbedding).values(
            name=plan.name,
            description=plan.description,
            content_hash=hash_source_text(_embed_text(plan)),
            embedding=vector,
            model=embedding_client.model,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=["name"],
            set_={
                "description": stmt.excluded.description,
                "content_hash": stmt.excluded.content_hash,
                "embedding": stmt.excluded.embedding,
                "model": stmt.excluded.model,
            },
        )
        await session.execute(stmt)
    await session.commit()
    return len(stale)


async def search_plans(
    session: AsyncSession,
    embedding_client: EmbeddingClient,
    *,
    query: str,
    top_k: int,
    threshold: float,
) -> list[SimilarPlan]:
    """Embeds query and returns up to top_k indexed plans (under the
    client's current model) whose cosine similarity is >= threshold, most
    similar first. Callers should call index_plan_catalog with the
    current plan list first — this function only searches what's already
    indexed, it doesn't index anything itself."""
    vectors = await embedding_client.embed([query])
    query_vector = vectors[0]

    distance = PlanEmbedding.embedding.cosine_distance(query_vector)
    rows = (
        await session.execute(
            select(PlanEmbedding, distance.label("distance"))
            .where(PlanEmbedding.model == embedding_client.model)
            .order_by(distance)
            .limit(top_k)
        )
    ).all()

    results = []
    for row, dist in rows:
        similarity = 1 - dist
        if similarity >= threshold:
            results.append(SimilarPlan(name=row.name, description=row.description, similarity=similarity))
    return results
