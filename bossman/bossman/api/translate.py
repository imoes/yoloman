"""POST /api/v1/translate — the authoring-time entry point for the real
LLM translator (see services/translator.py and docs/plan.md's "real LLM
translator"). Deliberately REST-only, no MCP tool: translation is a
one-off authoring action for a human/CI to review before a plan file is
committed, not a runtime fleet-management action an AI orchestrator needs
(see docs/plan.md's earlier, explicit scope cut: "kein KI-Übersetzer via
MCP heute").
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.api.chunks import get_embedding_client
from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services.chat_client import ChatClient
from bossman.services.embedding_client import EmbeddingClient
from bossman.services.translator import TranslationError, translate_chunk

router = APIRouter()


async def get_chat_client(request: Request) -> ChatClient:
    return request.app.state.chat_client


class TranslateRequest(BaseModel):
    plan_name: str
    chunk_name: str
    source_text: str
    threshold: float | None = None
    max_retries: int = 2


class TranslateResponse(BaseModel):
    source: str
    chunk: dict[str, Any]
    similar_chunk_id: str | None
    attempts: int


@router.post("/api/v1/translate", response_model=TranslateResponse)
async def translate_route(
    body: TranslateRequest,
    session: AsyncSession = Depends(get_session),
    embedding_client: EmbeddingClient = Depends(get_embedding_client),
    chat_client: ChatClient = Depends(get_chat_client),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> TranslateResponse:
    threshold = body.threshold if body.threshold is not None else settings.chunk_similarity_threshold
    try:
        result = await translate_chunk(
            session,
            embedding_client,
            chat_client,
            plan_name=body.plan_name,
            chunk_name=body.chunk_name,
            source_text=body.source_text,
            similarity_threshold=threshold,
            max_retries=body.max_retries,
        )
    except TranslationError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    return TranslateResponse(
        source=result.source,
        chunk={
            "name": result.chunk.name,
            "os_family": result.chunk.os_family,
            "steps": [
                {
                    "name": s.name,
                    "module": s.module,
                    "params": s.body,
                    "when": s.when,
                    "register": s.register,
                }
                for s in result.chunk.steps
            ],
        },
        similar_chunk_id=result.similar_chunk_id,
        attempts=result.attempts,
    )
