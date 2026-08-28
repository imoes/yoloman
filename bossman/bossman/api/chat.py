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
    OPENROUTER,
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


async def _build_backend(
    settings: Settings, oauth: ChatOAuthService, username: str, backend_name: str, model: str | None,
    hermes_base_url: str | None = None, hermes_model: str | None = None,
):
    """Construct the selected backend with this user's credentials from their
    bind-mounted home dir. Codex reads its access token from the home (proactively
    refreshed); claude runs with HOME set to it; hermes_web is server-side. The
    hermes endpoint/model come from the user's Settings (ChatPreference) when set,
    else the deploy-time default."""
    if backend_name == HERMES_WEB:
        return HermesWebBackend(
            hermes_base_url or settings.hermes_web_base_url,
            model or hermes_model or settings.hermes_web_model,
            settings.hermes_web_token,
        )
    if backend_name == OPENROUTER:
        # OpenAI-compatible; token stays server-side (env, never in prefs). The
        # per-user base_url/model prefs (shared with hermes) override the defaults.
        return HermesWebBackend(
            hermes_base_url or settings.openrouter_base_url,
            model or hermes_model or settings.openrouter_model,
            settings.openrouter_token,
            name=OPENROUTER,
        )
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
    hermes_base_url: str | None = None
    hermes_model: str | None = None


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
    """Begin the OAuth device flow for the Codex backend. Returns what the user must visit.

    Poll `.../codex/poll/{session_id}` afterwards. 502 when the provider itself cannot be reached
    — a distinct case from a rejected authorisation, which the poll reports.
    """
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
    """Ask whether that authorisation has completed yet.

    On success the credentials are written into **this user's** chat home on the server and the
    response is `{"status": "authorized"}` and nothing else — **the tokens are never returned to
    the client.** A browser that never receives a token cannot leak one.

    Any other status is returned as the provider gave it, so a caller can distinguish "still
    waiting" from "denied" instead of retrying a decision that has already been made. 400 when the
    flow itself is invalid or expired.
    """
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
    """Begin the Claude login flow; returns the URL to visit and what to send back.

    The counterpart is `.../claude/complete`, not a poll: this flow hands the user a code rather
    than waiting on the provider.
    """
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
    """Finish the Claude login with the code the user pasted back.

    As with Codex, the credentials land in the user's server-side chat home and no token is
    returned to the client.
    """
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
    """This user's chat preferences, with the server's defaults filled in where unset.

    Every field answers as "what would be used right now": an unset `default_backend` reads as the
    server's configured one rather than as `null`, so a caller never has to know the fallback rules
    to display the effective value. `models` maps a backend to the model chosen for it.
    """
    prefs = await _load_prefs(session, identity.name)
    return {
        "default_backend": prefs.default_backend if prefs else settings.chat_backend,
        "models": (prefs.models if prefs else {}) or {},
        "hermes_base_url": (prefs.hermes_base_url if prefs else None) or settings.hermes_web_base_url,
        "hermes_model": (prefs.hermes_model if prefs else None) or settings.hermes_web_model,
    }


@router.patch("/api/v1/chat/prefs")
async def set_prefs(
    body: PrefsRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Change chat preferences; omitted fields stay as they are.

    `models` is **merged**, not replaced — setting the model for one backend does not forget the
    others. 422 when `default_backend` is not a known backend.
    """
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
    if body.hermes_base_url is not None:
        prefs.hermes_base_url = body.hermes_base_url.strip() or None
    if body.hermes_model is not None:
        prefs.hermes_model = body.hermes_model.strip() or None
    await session.commit()
    return {
        "default_backend": prefs.default_backend, "models": prefs.models or {},
        "hermes_base_url": prefs.hermes_base_url or settings.hermes_web_base_url,
        "hermes_model": prefs.hermes_model or settings.hermes_web_model,
    }


@router.post("/api/v1/chat/sessions")
async def create_session(
    body: CreateSessionRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Start a chat session, pinned to one backend for its lifetime.

    The backend comes from the body, else this user's preference, else the server default; it must
    be one of the known backends (422). **It cannot be changed afterwards** — see `send_message`
    for why a session is pinned rather than re-selectable per message.
    """
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
    """This user's chat sessions, **most recently active first** (not most recently created).

    Sessions are per-user and not shared; another user's session is invisible rather than
    forbidden. Each row carries its message count, so a client need not fetch a transcript to show
    how long a conversation is.
    """
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
    """The full transcript of one session, in sequence order.

    Only the caller's own sessions (404 otherwise — not 403, because whether someone else's session
    id exists is not this caller's business). The system prompt is **not** part of the transcript:
    it is injected per request and never stored, so it can be improved without rewriting history.
    """
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
    """Change a session's label. The transcript and the pinned backend are untouched."""
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
    """Delete a session and its messages. Only your own; 404 for anything else."""
    s = await _owned_session(session, sid, identity.name)
    await session.delete(s)
    await session.commit()


# ---- W2: generative dashboard ----------------------------------------------


@router.get("/api/v1/chat/dashboard")
async def get_generated_dashboard(
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """The dashboard this user's chat generated for them, if there is one.

    Generated content, kept separate from the hand-arranged dashboards
    (`/api/v1/dashboards`): a model-authored layout must not be mistaken for one a person built,
    and neither should overwrite the other.
    """
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
        backend = await _build_backend(settings, oauth, identity.name, backend_name, model,
                                       hermes_base_url=(prefs.hermes_base_url if prefs else None),
                                       hermes_model=(prefs.hermes_model if prefs else None))
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


def _plans_summary(request: Request) -> str:
    """Compact catalog of runnable plans (name · description · params) for the
    task→bm-form doctrine, so the assistant can map a task to a plan."""
    cache = getattr(request.app.state, "catalog_cache", None)
    plans = getattr(cache, "plans", None) or []
    lines: list[str] = []
    for p in plans:
        params = ", ".join(
            f"{n}({spec.type}{'*' if spec.required else ''})" for n, spec in (p.params or {}).items()
        )
        desc = (p.description or "").splitlines()[0][:100]
        lines.append(f"- {p.name}: {desc}" + (f" | params: {params}" if params else ""))
    return "\n".join(lines)


@router.post("/api/v1/chat/sessions/{sid}/message")
async def send_message(
    sid: UUID,
    body: MessageRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity),
    session_factory: async_sessionmaker[AsyncSession] = Depends(get_session_factory),
    oauth: ChatOAuthService = Depends(get_chat_oauth),
) -> StreamingResponse:
    """Send a turn and stream the answer back as server-sent events.

    **The session's backend is authoritative.** A `backend` in the body is accepted only if it
    matches the session's; otherwise **409**, naming the pin. Letting a per-request field redirect
    a pinned session is how a conversation ends up half-answered by two different models, each
    unaware of the other's turns.

    What happens in order: the user's turn is persisted first (so a crash mid-answer cannot lose
    the question), the whole transcript is loaded, and a **non-persisted** system prompt is
    prepended. That prompt is not stored on purpose — it can be improved without rewriting what
    people actually said.

    With an agentic backend the model may **call fleet tools**, executed in-process against a
    session held open for the whole loop. Those calls do what they say: they are the same actions
    the UI performs, subject to the same authorisation as the caller. This endpoint is therefore a
    write surface, whatever it looks like.

    422 for empty content, for an unknown backend, or when the backend cannot be built (missing
    credentials, unreachable endpoint) — the message says which.
    """
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
    messages = [{"role": "system", "content": build_system_prompt(_plans_summary(request))}]
    messages += [{"role": m.role, "content": m.content} for m in history_rows]
    assistant_seq = next_seq + 1

    try:
        backend = await _build_backend(settings, oauth, identity.name, backend_name, model,
                                       hermes_base_url=(prefs.hermes_base_url if prefs else None),
                                       hermes_model=(prefs.hermes_model if prefs else None))
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
                # Pass our session id so a CLI backend (Claude) can resume its
                # own durable transcript by id instead of re-sending history.
                async for frame in pump(backend.stream(messages, session_id=str(sid))):
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
