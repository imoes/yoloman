"""Block K — unit tests for the three chat backend adapters. No DB: hermes/
codex use an httpx MockTransport (streamed SSE bytes); claude_cli uses an
injected fake spawn. These verify the adapters reduce each backend's wire
format to the common {type:'delta', text} event stream.
"""

import json

import httpx
import pytest

from bossman.services.chat_backend import (
    BACKENDS,
    ChatBackendError,
    ClaudeCliBackend,
    CodexBackend,
    HermesWebBackend,
    chat_backend_for,
)


def _sse(*frames: str) -> bytes:
    return ("".join(f"data: {f}\n\n" for f in frames)).encode("utf-8")


async def _collect(backend, messages, **kw) -> list[dict]:
    return [ev async for ev in backend.stream(messages, **kw)]


async def test_hermes_web_streams_deltas():
    body = _sse(
        json.dumps({"choices": [{"delta": {"content": "Hel"}}]}),
        json.dumps({"choices": [{"delta": {"content": "lo"}}]}),
        "[DONE]",
    )
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["json"] = json.loads(request.content)
        return httpx.Response(200, content=body)

    b = HermesWebBackend("http://hermes:8642", "hermes-agent", transport=httpx.MockTransport(handler))
    events = await _collect(b, [{"role": "user", "content": "hi"}], system="be nice")
    assert [e["text"] for e in events if e["type"] == "delta"] == ["Hel", "lo"]
    # system prepended, stream requested
    assert seen["json"]["messages"][0] == {"role": "system", "content": "be nice"}
    assert seen["json"]["stream"] is True


async def test_hermes_web_non200_raises():
    b = HermesWebBackend("http://hermes:8642", "m",
                         transport=httpx.MockTransport(lambda r: httpx.Response(500, content=b"boom")))
    with pytest.raises(ChatBackendError):
        await _collect(b, [{"role": "user", "content": "hi"}])


async def test_codex_streams_deltas():
    body = _sse(
        json.dumps({"type": "response.output_text.delta", "delta": "Hi "}),
        json.dumps({"type": "response.output_text.delta", "delta": "there"}),
        json.dumps({"type": "response.completed"}),
    )
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["json"] = json.loads(request.content)
        seen["auth"] = request.headers.get("authorization")
        return httpx.Response(200, content=body)

    b = CodexBackend("https://codex/api", "gpt-5.5", access_token="tok", transport=httpx.MockTransport(handler))
    events = await _collect(b, [{"role": "user", "content": "hi"}], system="sys")
    assert "".join(e["text"] for e in events) == "Hi there"
    assert seen["auth"] == "Bearer tok"
    assert seen["json"]["instructions"] == "sys"
    assert seen["json"]["input"][0]["content"][0]["text"] == "hi"


async def test_codex_missing_token_raises():
    b = CodexBackend("https://codex/api", "m", access_token="")
    with pytest.raises(ChatBackendError):
        await _collect(b, [{"role": "user", "content": "hi"}])


async def test_claude_cli_yields_result():
    captured = {}

    async def fake_spawn(argv, stdin_text, env=None):
        captured["argv"] = argv
        captured["stdin"] = stdin_text
        captured["env"] = env
        return 0, json.dumps({"type": "result", "result": "Hello from claude"}), ""

    b = ClaudeCliBackend("claude", "sonnet", home="/var/lib/bossman/chat-homes/alice", spawn=fake_spawn)
    events = await _collect(b, [{"role": "user", "content": "what's up"}], system="be terse")
    assert [e["text"] for e in events] == ["Hello from claude"]
    assert "--print" in captured["argv"] and "--system-prompt" in captured["argv"]
    assert captured["stdin"] == "what's up"  # lone user turn passed verbatim
    assert captured["env"]["HOME"] == "/var/lib/bossman/chat-homes/alice"  # per-user home for the CLI


async def test_claude_cli_nonzero_exit_raises():
    async def fake_spawn(argv, stdin_text, env=None):
        return 1, "", "auth error"

    b = ClaudeCliBackend("claude", "sonnet", spawn=fake_spawn)
    with pytest.raises(ChatBackendError):
        await _collect(b, [{"role": "user", "content": "hi"}])


async def test_claude_cli_is_error_result_raises():
    async def fake_spawn(argv, stdin_text, env=None):
        return 0, json.dumps({"type": "result", "is_error": True, "result": "nope"}), ""

    b = ClaudeCliBackend("claude", "sonnet", spawn=fake_spawn)
    with pytest.raises(ChatBackendError):
        await _collect(b, [{"role": "user", "content": "hi"}])


def test_chat_backend_for_selects_and_rejects():
    from bossman.config import Settings

    s = Settings(database_url="postgresql+asyncpg://unused/unused")
    assert chat_backend_for(s, "claude_cli").name == "claude_cli"
    assert chat_backend_for(s, "hermes_web").name == "hermes_web"
    assert chat_backend_for(s, "codex").name == "codex"
    assert chat_backend_for(s, "openrouter").name == "openrouter"
    with pytest.raises(ChatBackendError):
        chat_backend_for(s, "bogus")
    # The exhaustive list is asserted on purpose: adding a backend without deciding
    # that it belongs here should fail. It did — openrouter was added and this
    # assertion caught it, but the failure sat unnoticed among the DB-dependent
    # tests that cannot run from the host at all (docs/logik-audit.md: a test that
    # never runs is not an observation point).
    assert set(BACKENDS) == {"claude_cli", "codex", "hermes_web", "openrouter"}
