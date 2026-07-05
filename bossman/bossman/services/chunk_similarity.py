"""The chunk-similarity cache: a fuzzy, additive layer on top of
plan_loader's exact chunk_id/source_hash comparison (see
plan_loader.chunks_needing_retranslation and docs/plan.md's "Chunk-
similarity embedding cache"). Intended two-stage lookup for a future
translator: check the exact hash first (free, deterministic) — only for
source chunks that come back "new" does it make sense to embed the source
text and look for a close, already-translated chunk to suggest reusing
instead of re-translating from scratch.

Framework-free (no FastAPI import), like services/plan_engine.py and
services/poller.py, so it's reachable from the REST API, a future
translator, and tests without duplicating logic.
"""

from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import ChunkEmbedding
from bossman.services.embedding_client import EmbeddingClient


@dataclass
class SimilarChunk:
    chunk_id: str
    plan_name: str
    chunk_name: str
    source_hash: str | None
    similarity: float
    source_text: str


async def index_chunk(
    session: AsyncSession,
    embedding_client: EmbeddingClient,
    *,
    plan_name: str,
    chunk_name: str,
    chunk_id: str,
    source_hash: str | None,
    source_text: str,
) -> bool:
    """Embeds and upserts one chunk's source text, keyed by its own
    content-addressed chunk_id — one row per distinct translated chunk
    content, regardless of which plan/file produced it. Returns False
    without calling the embedding endpoint at all if a row for this exact
    chunk_id under this exact model already exists (the cache hit this
    whole cache exists for); True if a real embed+upsert happened."""
    existing = await session.scalar(
        select(ChunkEmbedding).where(
            ChunkEmbedding.chunk_id == chunk_id, ChunkEmbedding.model == embedding_client.model
        )
    )
    if existing is not None:
        return False

    vectors = await embedding_client.embed([source_text])
    stmt = insert(ChunkEmbedding).values(
        chunk_id=chunk_id,
        plan_name=plan_name,
        chunk_name=chunk_name,
        source_hash=source_hash,
        source_text=source_text,
        embedding=vectors[0],
        model=embedding_client.model,
    )
    stmt = stmt.on_conflict_do_update(
        index_elements=["chunk_id"],
        set_={
            "plan_name": stmt.excluded.plan_name,
            "chunk_name": stmt.excluded.chunk_name,
            "source_hash": stmt.excluded.source_hash,
            "source_text": stmt.excluded.source_text,
            "embedding": stmt.excluded.embedding,
            "model": stmt.excluded.model,
        },
    )
    await session.execute(stmt)
    await session.commit()
    return True


async def find_similar_chunks(
    session: AsyncSession,
    embedding_client: EmbeddingClient,
    *,
    source_text: str,
    top_k: int,
    threshold: float,
) -> list[SimilarChunk]:
    """Embeds source_text and returns up to top_k already-indexed chunks
    (under the client's current model — a model switch's old rows are
    invisible here, since their vectors live in an incomparable space)
    whose cosine similarity is >= threshold, most similar first. An empty
    result means "nothing close enough to suggest reusing", not an error."""
    vectors = await embedding_client.embed([source_text])
    query_vector = vectors[0]

    distance = ChunkEmbedding.embedding.cosine_distance(query_vector)
    rows = (
        await session.execute(
            select(ChunkEmbedding, distance.label("distance"))
            .where(ChunkEmbedding.model == embedding_client.model)
            .order_by(distance)
            .limit(top_k)
        )
    ).all()

    results = []
    for row, dist in rows:
        similarity = 1 - dist
        if similarity >= threshold:
            results.append(
                SimilarChunk(
                    chunk_id=row.chunk_id,
                    plan_name=row.plan_name,
                    chunk_name=row.chunk_name,
                    source_hash=row.source_hash,
                    similarity=similarity,
                    source_text=row.source_text,
                )
            )
    return results
