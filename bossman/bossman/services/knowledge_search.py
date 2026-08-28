"""Semantic retrieval over the infra knowledge index (services/knowledge_index.py).

Embed the question, return the most cosine-similar knowledge cards across the
whole fleet (optionally scoped to one host). This is the "retrieve" half of the
infra-grounded RAG; api/knowledge.py does the "generate" half.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import KnowledgeEmbedding
from bossman.services.embedding_client import EmbeddingClient

_MAX_LEXICAL_SCAN = 5000
_TOKEN = re.compile(r"[a-z0-9_.:/-]+")


@dataclass
class Hit:
    doc_id: str
    kind: str
    title: str
    text: str
    host_id: str | None
    similarity: float
    retriever: str = "semantic"


async def search(
    session: AsyncSession,
    embedding_client: EmbeddingClient,
    query: str,
    *,
    top_k: int = 8,
    host_id: UUID | None = None,
    min_similarity: float = 0.0,
) -> list[Hit]:
    """Top-k knowledge cards for `query`, most similar first. Filters to the
    current embedding model (old vectors live in an incomparable space); an
    empty result means nothing is indexed / close enough, not an error."""
    if not query.strip():
        return []
    vectors = await embedding_client.embed([query])
    qv = vectors[0]

    distance = KnowledgeEmbedding.embedding.cosine_distance(qv)
    stmt = (
        select(KnowledgeEmbedding, distance.label("distance"))
        .where(KnowledgeEmbedding.model == embedding_client.model)
        .order_by(distance)
        .limit(top_k)
    )
    if host_id is not None:
        stmt = stmt.where(KnowledgeEmbedding.host_id == host_id)

    rows = (await session.execute(stmt)).all()
    hits: list[Hit] = []
    for row, dist in rows:
        similarity = 1 - float(dist)
        if similarity < min_similarity:
            continue
        hits.append(Hit(
            doc_id=row.doc_id, kind=row.kind, title=row.title, text=row.text,
            host_id=str(row.host_id) if row.host_id else None,
            similarity=round(similarity, 4), retriever="semantic"))
    return hits


async def search_lexical(
    session: AsyncSession,
    query: str,
    *,
    top_k: int = 8,
    host_id: UUID | None = None,
) -> list[Hit]:
    """Keyword-overlap retrieval over the same cards — the fallback when no embed
    model is available (or it returned nothing). Needs NO vector DB: it scores each
    card by how many distinct query tokens appear in its title/text. This is what
    keeps the AI grounded even on a stack without an embeddings endpoint."""
    terms = {t for t in _TOKEN.findall(query.lower()) if len(t) > 2}
    if not terms:
        return []
    stmt = select(KnowledgeEmbedding).limit(_MAX_LEXICAL_SCAN)
    if host_id is not None:
        stmt = stmt.where(KnowledgeEmbedding.host_id == host_id)
    rows = (await session.scalars(stmt)).all()

    scored: list[tuple[float, KnowledgeEmbedding]] = []
    for row in rows:
        hay = (row.title + "\n" + row.text).lower()
        title_l = row.title.lower()
        score = 0.0
        for t in terms:
            if t in hay:
                score += 1.0
            if t in title_l:      # a title hit is worth more (it's the host/topic)
                score += 0.5
        if score > 0:
            scored.append((score, row))
    scored.sort(key=lambda x: x[0], reverse=True)

    max_score = (len(terms) * 1.5) or 1.0
    hits: list[Hit] = []
    for score, row in scored[:top_k]:
        hits.append(Hit(
            doc_id=row.doc_id, kind=row.kind, title=row.title, text=row.text,
            host_id=str(row.host_id) if row.host_id else None,
            similarity=round(min(score / max_score, 1.0), 4), retriever="lexical"))
    return hits
