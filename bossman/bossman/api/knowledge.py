"""Ask-the-infrastructure API — infra-grounded RAG.

POST /api/v1/ask                  answer a natural-language question from the live
                                  fleet: retrieve the relevant knowledge cards
                                  (services/knowledge_search) and have the LLM
                                  answer STRICTLY from them, citing hosts + sources
POST /api/v1/knowledge/reindex    rebuild the knowledge index now (admin)
GET  /api/v1/knowledge/stats      what is indexed (counts by kind, model, freshness)

The point: one question, and the AI reasons across every host — spotting
relationships and proposing concrete solutions — instead of a per-host doc dump.
"""
from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity, require_admin
from bossman.db.models import KnowledgeEmbedding
from bossman.db.session import get_session
from bossman.services import knowledge_index, knowledge_search
from bossman.services.embedding_client import EmbeddingClientError

router = APIRouter()

_SYS_ASK = (
    "You are the operator assistant for a Linux fleet managed by Bossman. Answer the "
    "question STRICTLY from the INFRASTRUCTURE FACTS below — each fact is a labelled "
    "card about a real host (its identity/health, current problems, or network "
    "connections). Never invent hosts, versions, or values that are not in the facts. "
    "Cite the host name(s) you used. When the facts reveal a RELATIONSHIP or likely "
    "root cause (e.g. a host that is CRIT and talks to another that drifted), say so "
    "explicitly. Then propose concrete next actions the operator can take in Bossman "
    "(adjust a threshold, fix a config file / resync drift, roll out an agent update, "
    "run a runbook) — but do NOT claim you performed them. If the facts are "
    "insufficient, say what is missing and suggest reindexing or naming the host."
)


class AskRequest(BaseModel):
    question: str
    host_id: UUID | None = None
    top_k: int = 8


@router.post("/api/v1/ask")
async def ask(
    body: AskRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """Retrieve-then-generate over the live infrastructure knowledge index."""
    if not body.question.strip():
        raise HTTPException(status_code=422, detail="empty question")
    embedding_client = request.app.state.embedding_client
    chat_client = request.app.state.chat_client
    top_k = max(1, min(body.top_k, 20))

    # Hybrid retrieval: prefer semantic (vector) recall, but fall back to lexical
    # over the SAME cards whenever the embed endpoint is missing/unreachable or
    # returns nothing — so "ask the infrastructure" works even without a vector DB.
    retriever = "semantic"
    hits: list = []
    try:
        hits = await knowledge_search.search(
            session, embedding_client, body.question, top_k=top_k, host_id=body.host_id)
    except EmbeddingClientError:
        hits = []
    if not hits:
        hits = await knowledge_search.search_lexical(
            session, body.question, top_k=top_k, host_id=body.host_id)
        retriever = "lexical"

    if not hits:
        return {
            "question": body.question,
            "answer": "I don't have any indexed infrastructure knowledge that matches this "
                      "question yet. Try reindexing (Settings ▸ Infrastructure knowledge) or "
                      "ask about a specific host by name.",
            "sources": [], "retriever": retriever, "grounding": {"cards": 0, "context_chars": 0},
        }

    context = "\n\n".join(f"[{h.kind}] {h.title}\n{h.text}" for h in hits)
    user = f"INFRASTRUCTURE FACTS:\n{context}\n\nQUESTION: {body.question}"
    answer = await chat_client.complete_text([
        {"role": "system", "content": _SYS_ASK},
        {"role": "user", "content": user},
    ])
    return {
        "question": body.question,
        "answer": answer,
        "sources": [
            {"doc_id": h.doc_id, "kind": h.kind, "title": h.title,
             "host_id": h.host_id, "similarity": h.similarity}
            for h in hits
        ],
        "retriever": retriever,
        "grounding": {"cards": len(hits), "context_chars": len(context)},
    }


@router.post("/api/v1/knowledge/reindex")
async def reindex(
    request: Request,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(require_admin),
) -> dict:
    """Rebuild the infra knowledge index now (incremental — only changed cards
    are re-embedded)."""
    stats = await knowledge_index.reindex(session, request.app.state.embedding_client)
    return stats


@router.get("/api/v1/knowledge/stats")
async def stats(
    request: Request,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """What the AI currently knows: card counts by kind, the embedding model, and
    how fresh the index is."""
    model = request.app.state.embedding_client.model
    rows = (await session.execute(
        select(KnowledgeEmbedding.kind, func.count())
        .where(KnowledgeEmbedding.model == model)
        .group_by(KnowledgeEmbedding.kind)
    )).all()
    last = (await session.execute(
        select(func.max(KnowledgeEmbedding.updated_at)).where(KnowledgeEmbedding.model == model)
    )).scalar_one_or_none()
    by_kind = {kind: count for kind, count in rows}
    return {
        "model": model,
        "total": sum(by_kind.values()),
        "by_kind": by_kind,
        "last_indexed": last.isoformat() if last else None,
    }
