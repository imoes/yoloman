"""Block K — pluggable AI chat backends behind one streaming interface.

The docked chatbot routes a conversation to one of three selectable backends,
all reduced to the same async event stream so the chat router (and the UI)
don't care which one is active:

- HermesWebBackend  — OpenAI-compatible server (hermes gateway, /v1/chat/completions SSE).
- CodexBackend      — ChatGPT's unofficial Codex Responses endpoint (SSE), device-code OAuth.
- ClaudeCliBackend  — the local `claude --print` binary (subprocess).

Each `stream(messages, ...)` yields event dicts: {"type": "delta", "text": ...}
for assistant tokens, {"type": "error", "text": ...} on failure. Tool events
(agentic tool-calling, Block K3) reuse the same channel with
{"type": "tool_start"|"tool_done", ...}. The terminal [DONE] sentinel is the
router's concern, not the backend's.

Test seams: hermes/codex take an httpx transport (MockTransport); claude takes
an injectable async `spawn` so a fake subprocess can be supplied.
"""

from __future__ import annotations

import asyncio
import glob
import json
import logging
import os
from typing import TYPE_CHECKING, Any, AsyncIterator, Awaitable, Callable

import httpx

if TYPE_CHECKING:
    from bossman.config import Settings

logger = logging.getLogger(__name__)

# Backend names (also the values of settings.chat_backend / the request field).
CLAUDE_CLI = "claude_cli"
CODEX = "codex"
HERMES_WEB = "hermes_web"
OPENROUTER = "openrouter"
BACKENDS = (CLAUDE_CLI, CODEX, HERMES_WEB, OPENROUTER)


class ChatBackendError(Exception):
    """Raised when a chat backend fails to start or stream — carries a
    human-readable message that is surfaced to the UI as an error event."""


def _system_and_turns(messages: list[dict[str, str]]) -> tuple[str, list[dict[str, str]]]:
    """Split a message list into (system_prompt, non-system turns). Multiple
    system messages are joined; the rest keep their order."""
    system_parts = [m.get("content", "") for m in messages if m.get("role") == "system"]
    turns = [m for m in messages if m.get("role") != "system"]
    return "\n\n".join(p for p in system_parts if p), turns


class HermesWebBackend:
    """OpenAI-compatible chat backend (hermes gateway or any /v1 server).
    Streams `chat.completion.chunk` deltas via SSE."""

    name = HERMES_WEB

    def __init__(self, base_url: str, model: str, token: str = "", timeout: float = 300.0,
                 transport: httpx.AsyncBaseTransport | None = None):
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.token = token
        self._timeout = timeout
        self._transport = transport

    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.token}"} if self.token else {}

    async def complete_with_tools(self, messages: list[dict[str, Any]], tools: list[dict[str, Any]],
                                  *, model: str | None = None) -> dict[str, Any]:
        """One non-streaming round with function-calling — returns
        {content, tool_calls}. Powers the agentic loop (chat_agent.py): the
        model either asks to call tools or gives a final answer."""
        body = {"model": model or self.model, "messages": messages, "tools": tools,
                "tool_choice": "auto", "stream": False}
        url = f"{self.base_url}/v1/chat/completions"
        try:
            async with httpx.AsyncClient(timeout=self._timeout, headers=self._headers(),
                                         transport=self._transport) as client:
                resp = await client.post(url, json=body)
        except httpx.HTTPError as exc:
            raise ChatBackendError(f"hermes_web: request failed: {exc}") from exc
        if resp.status_code != 200:
            raise ChatBackendError(f"hermes_web: status {resp.status_code}: {resp.text[:2048]}")
        msg = ((resp.json().get("choices") or [{}])[0]).get("message") or {}
        return {"content": msg.get("content") or "", "tool_calls": msg.get("tool_calls") or []}

    async def stream(self, messages: list[dict[str, str]], *, system: str | None = None,
                     model: str | None = None) -> AsyncIterator[dict[str, Any]]:
        msgs = list(messages)
        if system:
            msgs = [{"role": "system", "content": system}] + msgs
        body = {"model": model or self.model, "messages": msgs, "stream": True}
        headers = self._headers()
        url = f"{self.base_url}/v1/chat/completions"
        try:
            async with httpx.AsyncClient(timeout=self._timeout, headers=headers, transport=self._transport) as client:
                async with client.stream("POST", url, json=body) as resp:
                    if resp.status_code != 200:
                        text = (await resp.aread()).decode("utf-8", "replace")[:2048]
                        raise ChatBackendError(f"hermes_web: status {resp.status_code}: {text}")
                    async for line in resp.aiter_lines():
                        for ev in _parse_openai_chunk_line(line):
                            yield ev
        except httpx.HTTPError as exc:
            raise ChatBackendError(f"hermes_web: request failed: {exc}") from exc


class CodexBackend:
    """ChatGPT Codex Responses endpoint (SSE). The access token is supplied by
    the caller (loaded per-user from chat_credentials, refreshed as needed) —
    the OAuth flow that mints it lives in services/chat_oauth.py."""

    name = CODEX

    def __init__(self, base_url: str, model: str, access_token: str = "",
                 timeout: float = 300.0, transport: httpx.AsyncBaseTransport | None = None):
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.access_token = access_token
        self._timeout = timeout
        self._transport = transport

    def _access_token(self) -> str:
        if not self.access_token:
            raise ChatBackendError("codex: not logged in — run the Codex device-code login first")
        return self.access_token

    async def stream(self, messages: list[dict[str, str]], *, system: str | None = None,
                     model: str | None = None, session_id: str | None = None) -> AsyncIterator[dict[str, Any]]:
        # session_id is accepted for a uniform call site; the OpenAI-compatible
        # Codex endpoint is stateless, so full history is re-sent via `messages`.
        sys_prompt, turns = _system_and_turns(messages)
        instructions = system or sys_prompt or "You are a helpful assistant."
        payload = {
            "model": model or self.model,
            "instructions": instructions,
            "input": [
                {"type": "message", "role": m.get("role", "user"),
                 "content": [{"type": "input_text", "text": m.get("content", "")}]}
                for m in turns
            ],
            "store": False,
            "stream": True,
        }
        headers = {"Authorization": f"Bearer {self._access_token()}", "Content-Type": "application/json"}
        url = f"{self.base_url}/responses"
        try:
            async with httpx.AsyncClient(timeout=self._timeout, headers=headers, transport=self._transport) as client:
                async with client.stream("POST", url, json=payload) as resp:
                    if resp.status_code != 200:
                        text = (await resp.aread()).decode("utf-8", "replace")[:2048]
                        raise ChatBackendError(f"codex: status {resp.status_code}: {text}")
                    async for line in resp.aiter_lines():
                        for ev in _parse_codex_line(line):
                            yield ev
        except httpx.HTTPError as exc:
            raise ChatBackendError(f"codex: request failed: {exc}") from exc


# An injectable spawn: (argv, stdin_text, env) -> (returncode, stdout, stderr).
SpawnFn = Callable[[list[str], str, "dict[str, str] | None"], Awaitable[tuple[int, str, str]]]


async def _default_spawn(argv: list[str], stdin_text: str, env: dict[str, str] | None = None) -> tuple[int, str, str]:
    proc = await asyncio.create_subprocess_exec(
        *argv, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        env=env,
    )
    out, err = await proc.communicate(stdin_text.encode("utf-8"))
    return proc.returncode or 0, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


class ClaudeCliBackend:
    """The local Claude Code CLI via `claude --print --output-format json`.
    One-shot per turn (token streaming is a later refinement): the conversation
    is rendered into the prompt, the system prompt passed via --system-prompt,
    and the JSON `.result` yielded as a single delta. Auth: the subprocess runs
    with HOME set to the user's bind-mounted home dir, where the OAuth flow
    wrote ~/.claude/.credentials.json — so the CLI reads/refreshes its own
    per-user credential natively."""

    name = CLAUDE_CLI

    def __init__(self, cli_path: str = "claude", model: str = "sonnet", home: str | None = None,
                 spawn: SpawnFn | None = None):
        self.cli_path = cli_path
        self.model = model
        self.home = home
        self._spawn = spawn or _default_spawn

    async def stream(self, messages: list[dict[str, str]], *, system: str | None = None,
                     model: str | None = None, session_id: str | None = None) -> AsyncIterator[dict[str, Any]]:
        sys_prompt, turns = _system_and_turns(messages)
        system_prompt = system or sys_prompt
        env = {**os.environ, "HOME": self.home} if self.home else None
        argv = [self.cli_path, "--print", "--output-format", "json", "--model", model or self.model]
        if system_prompt:
            argv += ["--system-prompt", system_prompt]

        # History like CentralStation: when we have a durable HOME + our own
        # session id, let Claude keep its native transcript — resume it by id and
        # send ONLY the new user turn, instead of re-rendering the whole history
        # into the prompt each call. Falls back to the flattened-transcript,
        # no-persistence mode when there's no session id / home.
        if session_id and self.home:
            home = self.home
            existing = glob.glob(f"{home}/.claude/projects/*/{session_id}.jsonl")
            argv += ["--resume", session_id] if existing else ["--session-id", session_id]
            prompt = _last_user(turns)
        else:
            argv += ["--no-session-persistence"]
            prompt = _render_transcript(turns)
        try:
            rc, out, err = await self._spawn(argv, prompt, env)
        except (OSError, FileNotFoundError) as exc:
            raise ChatBackendError(f"claude_cli: could not run {self.cli_path!r}: {exc}") from exc
        if rc != 0:
            raise ChatBackendError(f"claude_cli: exit {rc}: {(err or out)[:2048]}")
        text = _claude_result_text(out)
        if text:
            yield {"type": "delta", "text": text}


def _last_user(turns: list[dict[str, str]]) -> str:
    """The latest user turn — the only thing to send when Claude resumes its
    own transcript by session id (it already has the prior turns)."""
    for m in reversed(turns):
        if m.get("role") == "user":
            return m.get("content", "")
    return turns[-1].get("content", "") if turns else ""


def _render_transcript(turns: list[dict[str, str]]) -> str:
    """Render prior turns into a single prompt string for the one-shot CLI.
    A lone final user turn is passed verbatim; multi-turn history is labelled."""
    if len(turns) == 1 and turns[0].get("role") == "user":
        return turns[0].get("content", "")
    lines = []
    for m in turns:
        role = m.get("role", "user").capitalize()
        lines.append(f"{role}: {m.get('content', '')}")
    return "\n\n".join(lines)


def _claude_result_text(stdout: str) -> str:
    """Extract the assistant text from `claude --output-format json` stdout.
    Shape: {"type":"result","result":"...","is_error":bool,...}."""
    stdout = stdout.strip()
    if not stdout:
        return ""
    try:
        obj = json.loads(stdout)
    except ValueError:
        # Fallback: some builds emit the plain result on stdout.
        return stdout
    if isinstance(obj, dict):
        if obj.get("is_error"):
            raise ChatBackendError(f"claude_cli: {obj.get('result') or 'error'}")
        return str(obj.get("result") or obj.get("text") or "")
    return str(obj)


def _parse_openai_chunk_line(line: str) -> list[dict[str, Any]]:
    """Parse one SSE line of an OpenAI chat.completion stream into events."""
    line = line.strip()
    if not line or not line.startswith("data:"):
        return []
    data = line[len("data:"):].strip()
    if data == "[DONE]":
        return []
    try:
        obj = json.loads(data)
    except ValueError:
        return []
    events: list[dict[str, Any]] = []
    for choice in obj.get("choices", []) or []:
        delta = (choice.get("delta") or {}).get("content")
        if delta:
            events.append({"type": "delta", "text": delta})
    return events


def _parse_codex_line(line: str) -> list[dict[str, Any]]:
    """Parse one SSE line of a Codex Responses stream. Text arrives as
    events with type 'response.output_text.delta' carrying a 'delta' field."""
    line = line.strip()
    if not line or not line.startswith("data:"):
        return []
    data = line[len("data:"):].strip()
    if data == "[DONE]":
        return []
    try:
        obj = json.loads(data)
    except ValueError:
        return []
    if obj.get("type") == "response.output_text.delta":
        d = obj.get("delta")
        if d:
            return [{"type": "delta", "text": d}]
    return []


def chat_backend_for(settings: Settings, name: str | None = None):
    """Build the selected chat backend from Settings. `name` (a per-request
    override) falls back to settings.chat_backend."""
    backend = (name or settings.chat_backend or CLAUDE_CLI).strip()
    if backend == HERMES_WEB:
        return HermesWebBackend(settings.hermes_web_base_url, settings.hermes_web_model, settings.hermes_web_token)
    if backend == OPENROUTER:
        # OpenRouter is OpenAI-compatible → the same client, different base/model/token.
        return HermesWebBackend(settings.openrouter_base_url, settings.openrouter_model, settings.openrouter_token)
    if backend == CODEX:
        return CodexBackend(settings.codex_base_url, settings.codex_model)
    if backend == CLAUDE_CLI:
        return ClaudeCliBackend(settings.claude_cli_path, settings.claude_cli_model)
    # Note: codex/claude_cli built here carry no per-user token — the chat
    # router constructs them with credentials loaded from chat_credentials.
    raise ChatBackendError(f"unknown chat backend {backend!r} (want one of {', '.join(BACKENDS)})")
