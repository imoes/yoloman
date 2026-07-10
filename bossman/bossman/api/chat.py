"""Block K — the AI chat console: session CRUD + a streaming message endpoint.

POST /api/v1/chat/sessions/{sid}/message returns a text/event-stream: each
frame is `data: {json}\n\n` with a {type} of delta|tool_start|tool_done|error,
terminated by `data: [DONE]\n\n` — the transport CentralStation's console uses,
consumed on the client via fetch()+ReadableStream (an EventSource can't POST a
body or carry the bearer header). The selected ChatBackend (claude_cli/codex/
hermes_web) is reduced to that one event stream by services/chat_backend.py.

Sessions + turns persist in chat_sessions/chat_messages, keyed by the caller's
username (Identity.name). Ownership is enforced on every route.
"""

from __future__ import annotations

import json
from typing import Any, AsyncIterator
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.models import ChatMessage, ChatSession
from bossman.db.session import get_session
from bossman.services.chat_backend import BACKENDS, ChatBackendError, chat_backend_for

router = APIRouter()


def get_session_factory(request: Request) -> async_sessionmaker[AsyncSession]:
    return request.app.state.session_factory


class CreateSessionRequest(BaseModel):
    label: str | None = None
    backend: str | None = None


class RenameSessionRequest(BaseModel):
    label: str


class MessageRequest(BaseModel):
    content: str
    backend: str | None = None  # per-message backend override


def _session_out(s: ChatSession, msg_count: int | None = None) -> dict[str, Any]:
    return {
        "id": str(s.id),
        "label": s.label,
        "backend": s.backend,
        "created_at": s.created_at.isoformat() if s.created_at else None,
        "updated_at": s.updated_at.isoformat() if s.updated_at else None,
        "msg_count": msg_count,
    }


async def _owned_session(session: AsyncSession, sid: UUID, username: str) -> ChatSession:
    s = await session.get(ChatSession, sid)
    if s is None or s.username != username:
        raise HTTPException(status_code=404, detail=f"no such chat session {sid}")
    return s


@router.get("/api/v1/chat/backends")
async def list_chat_backends(
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """The selectable AI backends + the configured default — powers the UI's
    backend selector."""
    return {"backends": list(BACKENDS), "default": settings.chat_backend}


@router.post("/api/v1/chat/sessions")
async def create_session(
    body: CreateSessionRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    backend = (body.backend or settings.chat_backend).strip()
    if backend not in BACKENDS:
        raise HTTPException(status_code=422, detail=f"backend must be one of: {', '.join(BACKENDS)}")
    s = ChatSession(username=identity.name, label=body.label, backend=backend)
    session.add(s)
    await session.flush()
    await session.commit()
    return _session_out(s, msg_count=0)


@router.get("/api/v1/chat/sessions")
async def list_sessions(
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    rows = (
        await session.scalars(
            select(ChatSession).where(ChatSession.username == identity.name).order_by(ChatSession.updated_at.desc())
        )
    ).all()
    counts = dict(
        (
            await session.execute(
                select(ChatMessage.session_id, func.count(ChatMessage.id)).group_by(ChatMessage.session_id)
            )
        ).all()
    )
    return {"sessions": [_session_out(s, msg_count=int(counts.get(s.id, 0))) for s in rows]}


@router.get("/api/v1/chat/sessions/{sid}/history")
async def session_history(
    sid: UUID,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    await _owned_session(session, sid, identity.name)
    msgs = (
        await session.scalars(
            select(ChatMessage).where(ChatMessage.session_id == sid).order_by(ChatMessage.seq)
        )
    ).all()
    return {"messages": [{"role": m.role, "content": m.content, "meta": m.meta} for m in msgs]}


@router.patch("/api/v1/chat/sessions/{sid}")
async def rename_session(
    sid: UUID,
    body: RenameSessionRequest,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    s = await _owned_session(session, sid, identity.name)
    s.label = body.label
    await session.commit()
    return _session_out(s)


@router.delete("/api/v1/chat/sessions/{sid}", status_code=204)
async def delete_session(
    sid: UUID,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> None:
    s = await _owned_session(session, sid, identity.name)
    await session.delete(s)
    await session.commit()


@router.post("/api/v1/chat/sessions/{sid}/message")
async def send_message(
    sid: UUID,
    body: MessageRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
    session_factory: async_sessionmaker[AsyncSession] = Depends(get_session_factory),
) -> StreamingResponse:
    if not body.content.strip():
        raise HTTPException(status_code=422, detail="content must not be empty")
    s = await _owned_session(session, sid, identity.name)
    backend_name = (body.backend or s.backend).strip()
    if backend_name not in BACKENDS:
        raise HTTPException(status_code=422, detail=f"backend must be one of: {', '.join(BACKENDS)}")

    # Persist the user turn and load the full transcript (incl. it) up front,
    # while the request-scoped session is still open.
    next_seq = (
        await session.scalar(
            select(func.coalesce(func.max(ChatMessage.seq), -1) + 1).where(ChatMessage.session_id == sid)
        )
    ) or 0
    session.add(ChatMessage(session_id=sid, seq=next_seq, role="user", content=body.content))
    await session.commit()
    history_rows = (
        await session.scalars(
            select(ChatMessage).where(ChatMessage.session_id == sid).order_by(ChatMessage.seq)
        )
    ).all()
    messages = [{"role": m.role, "content": m.content} for m in history_rows]
    assistant_seq = next_seq + 1

    try:
        backend = chat_backend_for(settings, backend_name)
    except ChatBackendError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    async def event_stream() -> AsyncIterator[bytes]:
        parts: list[str] = []
        try:
            async for ev in backend.stream(messages):
                if ev.get("type") == "delta" and ev.get("text"):
                    parts.append(ev["text"])
                yield f"data: {json.dumps(ev)}\n\n".encode("utf-8")
        except ChatBackendError as exc:
            yield f"data: {json.dumps({'type': 'error', 'text': str(exc)})}\n\n".encode("utf-8")
        except Exception as exc:  # noqa: BLE001 — never leak a stack trace into the stream
            yield f"data: {json.dumps({'type': 'error', 'text': f'chat backend failed: {exc}'})}\n\n".encode("utf-8")
        # Persist the assistant turn with a fresh session (the request-scoped
        # one is gone by the time the stream drains).
        text = "".join(parts)
        if text:
            async with session_factory() as write:
                write.add(ChatMessage(session_id=sid, seq=assistant_seq, role="assistant", content=text))
                sess = await write.get(ChatSession, sid)
                if sess is not None:
                    sess.updated_at = func.now()
                await write.commit()
        yield b"data: [DONE]\n\n"

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
