"""POST /api/v1/chunks/index, /api/v1/chunks/similar — the authoring-time
surface for the chunk-similarity cache (see services/chunk_similarity.py
and docs/plan.md's "Chunk-similarity embedding cache"). Called by whoever
is translating a foreign source (an Ansible role, today a human/AI in a
chat session; later a real automated translator) — `similar` before
translating a chunk, to check for an already-translated near-match to
reuse; `index` after translating, to persist it for future lookups.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services.chunk_similarity import find_similar_chunks, index_chunk
from bossman.services.embedding_client import EmbeddingClient

router = APIRouter()


async def get_embedding_client(request: Request) -> EmbeddingClient:
    return request.app.state.embedding_client


class IndexChunkRequest(BaseModel):
    plan_name: str
    chunk_name: str
    chunk_id: str
    source_hash: str | None = None
    source_text: str
    # The actual translated chunk content (JSON), for symmetry with what
    # services/translator.py passes in-process — lets a human manually
    # registering a hand-translated chunk also make it reuse-reconstructable,
    # not just fuzzy-findable. See ChunkEmbedding.translated_json.
    translated_json: str | None = None


class IndexChunkResponse(BaseModel):
    indexed: bool
    chunk_id: str


@router.post("/api/v1/chunks/index", response_model=IndexChunkResponse)
async def index_chunk_route(
    body: IndexChunkRequest,
    session: AsyncSession = Depends(get_session),
    embedding_client: EmbeddingClient = Depends(get_embedding_client),
    _identity=Depends(get_current_identity),
) -> IndexChunkResponse:
    indexed = await index_chunk(
        session,
        embedding_client,
        plan_name=body.plan_name,
        chunk_name=body.chunk_name,
        chunk_id=body.chunk_id,
        source_hash=body.source_hash,
        source_text=body.source_text,
        translated_json=body.translated_json,
    )
    return IndexChunkResponse(indexed=indexed, chunk_id=body.chunk_id)


class SimilarChunksRequest(BaseModel):
    source_text: str
    top_k: int = 3
    threshold: float | None = None


class SimilarChunkOut(BaseModel):
    chunk_id: str
    plan_name: str
    chunk_name: str
    source_hash: str | None
    similarity: float
    source_text: str
    translated_json: str | None


class SimilarChunksResponse(BaseModel):
    candidates: list[SimilarChunkOut]


@router.post("/api/v1/chunks/similar", response_model=SimilarChunksResponse)
async def similar_chunks_route(
    body: SimilarChunksRequest,
    session: AsyncSession = Depends(get_session),
    embedding_client: EmbeddingClient = Depends(get_embedding_client),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> SimilarChunksResponse:
    threshold = body.threshold if body.threshold is not None else settings.chunk_similarity_threshold
    candidates = await find_similar_chunks(
        session, embedding_client, source_text=body.source_text, top_k=body.top_k, threshold=threshold
    )
    return SimilarChunksResponse(
        candidates=[
            SimilarChunkOut(
                chunk_id=c.chunk_id,
                plan_name=c.plan_name,
                chunk_name=c.chunk_name,
                source_hash=c.source_hash,
                similarity=c.similarity,
                source_text=c.source_text,
                translated_json=c.translated_json,
            )
            for c in candidates
        ]
    )
