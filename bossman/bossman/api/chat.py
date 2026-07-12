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
from bossman.db.models import ChatMessage, ChatPreference, ChatSession, GeneratedDashboard
from bossman.db.session import get_session
from bossman.services import chat_home
from bossman.services.chat_backend import (
    BACKENDS,
    CLAUDE_CLI,
    CODEX,
    HERMES_WEB,
    ChatBackendError,
    ClaudeCliBackend,
    CodexBackend,
    HermesWebBackend,
)
from bossman.services.chat_agent import backend_is_agentic, bind_executor, run_agentic
from bossman.services.chat_dashboard import generate_dashboard
from bossman.services.dashboard import create_ai_dashboard
from bossman.services.chat_oauth import ChatOAuthError, ChatOAuthService, token_needs_refresh
from bossman.services.chat_prompt import build_system_prompt

router = APIRouter()


def get_session_factory(request: Request) -> async_sessionmaker[AsyncSession]:
    return request.app.state.session_factory


def get_chat_oauth(request: Request) -> ChatOAuthService:
    return request.app.state.chat_oauth


async def _load_prefs(session: AsyncSession, username: str) -> ChatPreference | None:
    return await session.scalar(select(ChatPreference).where(ChatPreference.username == username))


async def _build_backend(settings: Settings, oauth: ChatOAuthService, username: str, backend_name: str, model: str | None):
    """Construct the selected backend with this user's credentials from their
    bind-mounted home dir. Codex reads its access token from the home (proactively
    refreshed); claude runs with HOME set to it; hermes_web is server-side."""
    if backend_name == HERMES_WEB:
        return HermesWebBackend(settings.hermes_web_base_url, model or settings.hermes_web_model, settings.hermes_web_token)
    home = chat_home.home_for(settings.chat_home_root, username)
    if backend_name == CLAUDE_CLI:
        return ClaudeCliBackend(settings.claude_cli_path, model or settings.claude_cli_model, home=str(home))
    if backend_name == CODEX:
        creds = chat_home.read_codex_credentials(home)
        access = creds.get("access_token", "")
        if access and creds.get("refresh_token") and token_needs_refresh(creds.get("expires_at") or 0):
            try:
                refreshed = await oauth.codex_refresh(creds["refresh_token"])
                chat_home.write_codex_credentials(
                    home, refreshed["access_token"], refreshed["refresh_token"], refreshed["expires_at"]
                )
                access = refreshed["access_token"]
            except ChatOAuthError:
                pass  # fall through with the (possibly stale) token; stream surfaces the error
        return CodexBackend(settings.codex_base_url, model or settings.codex_model, access_token=access)
    raise ChatBackendError(f"unknown chat backend {backend_name!r}")


class CreateSessionRequest(BaseModel):
    label: str | None = None
    backend: str | None = None


class RenameSessionRequest(BaseModel):
    label: str


class MessageRequest(BaseModel):
    content: str
    backend: str | None = None  # must match the session's backend if given


class ClaudeCompleteRequest(BaseModel):
    session_id: str
    code: str


class PrefsRequest(BaseModel):
    default_backend: str | None = None
    models: dict[str, str] | None = None


class GenerateDashboardRequest(BaseModel):
    prompt: str = ""
    backend: str | None = None


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


# ---- OAuth login (per-user, tokens written into the user's home dir) --------


@router.get("/api/v1/chat/oauth/status")
async def oauth_status(
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Which backends this user is logged in for. hermes_web is server-side
    (no per-user login)."""
    home = chat_home.home_for(settings.chat_home_root, identity.name)
    status = chat_home.auth_status(home)
    status["hermes_web"] = bool(settings.hermes_web_base_url)
    return {"authenticated": status}


@router.post("/api/v1/chat/oauth/codex/start")
async def codex_start(
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
    oauth: ChatOAuthService = Depends(get_chat_oauth),
) -> dict[str, Any]:
    try:
        return await oauth.codex_start(identity.name)
    except ChatOAuthError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.post("/api/v1/chat/oauth/codex/poll/{session_id}")
async def codex_poll(
    session_id: str,
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
    oauth: ChatOAuthService = Depends(get_chat_oauth),
) -> dict[str, Any]:
    try:
        result = await oauth.codex_poll(session_id, identity.name)
    except ChatOAuthError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if result.get("status") == "authorized":
        home = chat_home.home_for(settings.chat_home_root, identity.name)
        chat_home.write_codex_credentials(
            home, result["access_token"], result.get("refresh_token", ""), result.get("expires_at") or 0
        )
        return {"status": "authorized"}  # never leak tokens to the client
    return result


@router.post("/api/v1/chat/oauth/claude/start")
async def claude_start(
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
    oauth: ChatOAuthService = Depends(get_chat_oauth),
) -> dict[str, Any]:
    try:
        return await oauth.claude_start(identity.name)
    except ChatOAuthError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.post("/api/v1/chat/oauth/claude/complete")
async def claude_complete(
    body: ClaudeCompleteRequest,
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
    oauth: ChatOAuthService = Depends(get_chat_oauth),
) -> dict[str, Any]:
    try:
        result = await oauth.claude_complete(body.session_id, identity.name, body.code)
    except ChatOAuthError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    home = chat_home.home_for(settings.chat_home_root, identity.name)
    chat_home.write_claude_credentials(
        home, result["access_token"], result.get("refresh_token", ""), result.get("expires_at") or 0
    )
    return {"status": "authorized"}


# ---- Per-user console preferences ------------------------------------------


@router.get("/api/v1/chat/prefs")
async def get_prefs(
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    prefs = await _load_prefs(session, identity.name)
    return {
        "default_backend": prefs.default_backend if prefs else settings.chat_backend,
        "models": (prefs.models if prefs else {}) or {},
    }


@router.patch("/api/v1/chat/prefs")
async def set_prefs(
    body: PrefsRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    if body.default_backend and body.default_backend not in BACKENDS:
        raise HTTPException(status_code=422, detail=f"default_backend must be one of: {', '.join(BACKENDS)}")
    prefs = await _load_prefs(session, identity.name)
    if prefs is None:
        prefs = ChatPreference(username=identity.name, default_backend=settings.chat_backend, models={})
        session.add(prefs)
    if body.default_backend:
        prefs.default_backend = body.default_backend
    if body.models is not None:
        prefs.models = {**(prefs.models or {}), **body.models}
    await session.commit()
    return {"default_backend": prefs.default_backend, "models": prefs.models or {}}


@router.post("/api/v1/chat/sessions")
async def create_session(
    body: CreateSessionRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    prefs = await _load_prefs(session, identity.name)
    default_backend = prefs.default_backend if prefs else settings.chat_backend
    backend = (body.backend or default_backend).strip()
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


# ---- W2: generative dashboard ----------------------------------------------


@router.get("/api/v1/chat/dashboard")
async def get_generated_dashboard(
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    row = await session.scalar(select(GeneratedDashboard).where(GeneratedDashboard.username == identity.name))
    return {
        "prompt": row.prompt if row else "",
        "widgets": (row.widgets if row else []) or [],
        "created_at": row.created_at.isoformat() if row and row.created_at else None,
    }


@router.post("/api/v1/chat/dashboard/generate")
async def generate_dashboard_route(
    body: GenerateDashboardRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
    session_factory: async_sessionmaker[AsyncSession] = Depends(get_session_factory),
    oauth: ChatOAuthService = Depends(get_chat_oauth),
) -> dict[str, Any]:
    """Have the configured AI design a dashboard (it may call fleet tools for
    real data) and persist it for this user. Enabled once a backend is usable."""
    prefs = await _load_prefs(session, identity.name)
    backend_name = (body.backend or (prefs.default_backend if prefs else settings.chat_backend)).strip()
    if backend_name not in BACKENDS:
        raise HTTPException(status_code=422, detail=f"backend must be one of: {', '.join(BACKENDS)}")
    model = (prefs.models or {}).get(backend_name) if prefs else None
    try:
        backend = await _build_backend(settings, oauth, identity.name, backend_name, model)
    except ChatBackendError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    async with session_factory() as tool_sess:
        try:
            widgets = await generate_dashboard(backend, bind_executor(tool_sess), body.prompt)
        except ChatBackendError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc
    if not widgets:
        raise HTTPException(status_code=502, detail="the AI did not return any valid widgets — try rephrasing")

    row = await session.scalar(select(GeneratedDashboard).where(GeneratedDashboard.username == identity.name))
    if row is None:
        row = GeneratedDashboard(username=identity.name, prompt=body.prompt, widgets=widgets)
        session.add(row)
    else:
        row.prompt = body.prompt
        row.widgets = widgets
    await session.commit()
    # Block A3: also persist it as a real, editable named dashboard so it shows
    # up in the Fleet Overview picker alongside hand-built ones.
    dash = await create_ai_dashboard(session, identity.name, body.prompt, widgets)
    return {"prompt": body.prompt, "widgets": widgets, "dashboard_id": str(dash.id), "dashboard_name": dash.name}


@router.post("/api/v1/chat/sessions/{sid}/message")
async def send_message(
    sid: UUID,
    body: MessageRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
    session_factory: async_sessionmaker[AsyncSession] = Depends(get_session_factory),
    oauth: ChatOAuthService = Depends(get_chat_oauth),
) -> StreamingResponse:
    if not body.content.strip():
        raise HTTPException(status_code=422, detail="content must not be empty")
    s = await _owned_session(session, sid, identity.name)
    # The session's backend is authoritative (CentralStation lesson: never let a
    # per-request body override a session pinned to another agent). A body
    # backend is honored only if it matches.
    backend_name = s.backend
    if body.backend and body.backend != backend_name:
        raise HTTPException(
            status_code=409,
            detail=f"session is pinned to backend {backend_name!r}; start a new session to use {body.backend!r}",
        )
    if backend_name not in BACKENDS:
        raise HTTPException(status_code=422, detail=f"backend must be one of: {', '.join(BACKENDS)}")
    prefs = await _load_prefs(session, identity.name)
    model = (prefs.models or {}).get(backend_name) if prefs else None

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
    # Inject the (non-persisted) system prompt so the model knows how to emit
    # Markdown + bm-widget/plantuml blocks. Backends route a system message to
    # their own system slot (OpenAI system / claude --system-prompt).
    messages = [{"role": "system", "content": build_system_prompt()}]
    messages += [{"role": m.role, "content": m.content} for m in history_rows]
    assistant_seq = next_seq + 1

    try:
        backend = await _build_backend(settings, oauth, identity.name, backend_name, model)
    except ChatBackendError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    async def event_stream() -> AsyncIterator[bytes]:
        parts: list[str] = []

        async def pump(events) -> AsyncIterator[bytes]:
            async for ev in events:
                if ev.get("type") == "delta" and ev.get("text"):
                    parts.append(ev["text"])
                yield f"data: {json.dumps(ev)}\n\n".encode("utf-8")

        try:
            if backend_is_agentic(backend):
                # Agentic: the model can call fleet tools; execute them
                # in-process against a fresh session held for the whole loop.
                async with session_factory() as tool_sess:
                    from bossman.api.plans import get_client_factory

                    executor = bind_executor(tool_sess, settings=settings, client_factory=get_client_factory())
                    async for frame in pump(run_agentic(backend, messages, executor, model=model)):
                        yield frame
            else:
                async for frame in pump(backend.stream(messages)):
                    yield frame
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
