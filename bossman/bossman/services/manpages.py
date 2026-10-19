"""Manual-page lookup on a managed host — the agent's `manpage` module, one place for every LLM surface.

The manual pages installed on a host document exactly the versions that run there. With them a small model can look
up which option, directive or file does what instead of guessing from training data written for another release —
the most valuable reference an agentic OS has. The agent (agentic-mcpd ≥ 0.57.83) exposes the module as an MCP tool
of its own; Bossman's MCP server and its in-app assistant reach it through here.
"""

from __future__ import annotations

from typing import Any

#: The one description the MCP tool and the assistant's tool share.
DESCRIPTION = (
    "Look things up in the manual pages installed on a managed host — the documentation of exactly the versions "
    "that run there. Use it BEFORE changing a configuration you are not sure about. Two steps: (1) search with "
    "`query` (a few words, e.g. \"ssh daemon\"; add full_text=true to find an option or directive name inside the "
    "pages, e.g. \"PermitRootLogin\"); (2) read a page with `page` (+ `section`: 5 = file formats, 8 = daemons and "
    "admin commands, 1 = user commands), narrowed by `heading` (e.g. OPTIONS, FILES, EXAMPLES) or `grep` (a word — the "
    "paragraph that defines it comes first). If the host has no manual pages installed the result says so in `note`."
)

PARAMS = ("query", "full_text", "page", "section", "heading", "grep", "max_chars", "limit")


async def man_lookup(client: Any, args: dict[str, Any]) -> dict[str, Any]:
    """Call the agent's manpage module with the lookup arguments; the module's data, or a named error."""
    call = {k: args[k] for k in PARAMS if args.get(k) not in (None, "", False)}
    if not call.get("query") and not call.get("page"):
        return {"error": "give `query` to search or `page` to read"}
    call.setdefault("max_chars", 8000)   # a small model's context: one page section, not the whole manual
    try:
        res = await client.call_tool("manpage", call)
    except Exception as exc:  # noqa: BLE001 — an agent error is returned, named
        text = str(exc)
        if "unknown tool" in text.lower() or "not found" in text.lower() or "404" in text:
            return {"error": "this host's agent has no `manpage` module yet (agentic-mcpd ≥ 0.57.83) — update the "
                             "agent; until then call_agent_tool with `command` running `man -P cat <page>` may work"}
        return {"error": text}
    return res.get("data", res) if isinstance(res, dict) else {"error": "unexpected result from the agent"}
