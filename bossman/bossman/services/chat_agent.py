"""Block K3 — the agentic tool loop for tool-capable chat backends.

Given a backend exposing complete_with_tools() (currently hermes_web/qwen79b,
which supports OpenAI function-calling), run the loop: ask the model, and while
it requests tool calls, execute them in-process against the fleet
(chat_tools.execute_tool) and feed the results back — emitting tool_start/
tool_done events so the console shows what the AI is doing. When the model
returns a final answer instead of tool calls, emit it as delta(s). The AI can
thus answer with LIVE fleet data and render widgets from it.

Claude CLI is natively agentic via its own MCP client (a separate wiring) and
Codex uses the Responses API's function-calling shape; both are follow-ons —
this loop targets the OpenAI Chat-Completions tool shape.
"""

from __future__ import annotations

import json
import re
from typing import Any, AsyncIterator, Awaitable, Callable

from bossman.services.chat_backend import ChatBackendError
from bossman.services.chat_tools import TOOL_DEFS, execute_tool

# How many tool rounds before we force a final answer (runaway guard).
MAX_TOOL_ROUNDS = 4

# Some llama.cpp/qwen builds echo tool calls as literal text even when told not
# to call tools; strip that XML-ish junk from a final answer.
_TOOLCALL_JUNK = re.compile(r"<tool_call>.*?</tool_call>|</?function[^>]*>|<tool_call>|</tool_call>", re.DOTALL)


def _clean(content: str) -> str:
    return _TOOLCALL_JUNK.sub("", content or "").strip()

# executor(name, args) -> result dict (bound to a DB session by the caller).
ToolExecutor = Callable[[str, dict[str, Any]], Awaitable[dict[str, Any]]]


def backend_is_agentic(backend: Any) -> bool:
    """A backend can drive the tool loop if it implements complete_with_tools."""
    return hasattr(backend, "complete_with_tools")


async def run_agentic(
    backend: Any,
    messages: list[dict[str, Any]],
    executor: ToolExecutor,
    *,
    model: str | None = None,
) -> AsyncIterator[dict[str, Any]]:
    """Yield console events (tool_start/tool_done/delta) while looping the
    model + fleet tools. `messages` is mutated with the assistant/tool turns."""
    convo = list(messages)
    seen: set[str] = set()  # tool-call signatures already executed this turn
    for _ in range(MAX_TOOL_ROUNDS):
        try:
            result = await backend.complete_with_tools(convo, TOOL_DEFS, model=model)
        except ChatBackendError as exc:
            yield {"type": "error", "text": str(exc)}
            return
        tool_calls = result.get("tool_calls") or []
        if not tool_calls:
            content = _clean(result.get("content") or "")
            if content:
                yield {"type": "delta", "text": content}
                return
            break  # empty/tool-junk-only answer -> force a clean one below
        convo.append({"role": "assistant", "content": result.get("content") or "", "tool_calls": tool_calls})
        fresh = 0
        for call in tool_calls:
            fn = call.get("function") or {}
            name = fn.get("name") or ""
            raw_args = fn.get("arguments") or "{}"
            try:
                args = json.loads(raw_args)
            except ValueError:
                args = {}
            sig = f"{name}:{raw_args}"
            if sig in seen:
                # The model is re-requesting an identical call — feed the same
                # (already-known) result shape back without re-emitting events.
                convo.append({"role": "tool", "tool_call_id": call.get("id") or name, "name": name,
                              "content": json.dumps({"note": "already provided above"})})
                continue
            seen.add(sig)
            fresh += 1
            yield {"type": "tool_start", "tool": name}
            try:
                out = await executor(name, args)
                ok = "error" not in out
            except Exception as exc:  # noqa: BLE001 — a tool failure feeds back, doesn't crash the chat
                out = {"error": str(exc)}
                ok = False
            yield {"type": "tool_done", "tool": name, "ok": ok}
            convo.append({"role": "tool", "tool_call_id": call.get("id") or name, "name": name, "content": json.dumps(out)})
        if fresh == 0:
            break  # only duplicate calls this round -> stop looping, force an answer
    # Force a final, tool-free answer from the gathered results.
    try:
        final = await backend.complete_with_tools(convo, [], model=model)
        content = _clean(final.get("content") or "")
        yield {"type": "delta", "text": content or "(no answer)"}
    except ChatBackendError as exc:
        yield {"type": "error", "text": str(exc)}


def bind_executor(session, *, settings: Any = None, client_factory: Any = None) -> ToolExecutor:
    """Bind chat_tools.execute_tool to a DB session for the loop. settings +
    client_factory enable the host-reaching discovery tools (Block G9-P4);
    omit them for read-only-only contexts."""
    async def _exec(name: str, args: dict[str, Any]) -> dict[str, Any]:
        return await execute_tool(session, name, args, settings=settings, client_factory=client_factory)

    return _exec
