"""Let an OpenAI-compatible model drive Bossman through its MCP server — the probe for "can model X operate the
fleet" (docs/kernel-tuning.md, "A model deploys a host").

The model gets Bossman's operator guide as its system prompt and a chosen subset of the MCP tools as functions;
every tool call it makes is executed against the real MCP server with the given API token (so the host ACL, the
dry-run defaults and every refusal apply exactly as for any other client) and fed back. Each step is written to
a JSONL log with its duration, so a run can be read afterwards: what the model asked, what Bossman answered.

    python -m bossman.tools.mcp_agent --goal "..." --tools vm_hosts,check_ip,deploy_vm,deployment_status \\
        --base-url https://llm.example.internal/qwen27b --model qwen3.8-27b --token-file token.json

No `max_tokens` is ever sent: the model's own context bounds the answer. Thinking is off by default
(`--thinking` turns it on), because at ~1 token/s generation a long reasoning block costs minutes per step.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from pathlib import Path
from typing import Any

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

RULES = """You operate a real server fleet through Bossman's tools. Rules:
- Always run a write tool with dry_run=true first, read the result, and only then run it for real.
- Report every refusal (unsupported:, tool_unavailable:, conflict:, not authorized) with its reason instead of
  working around it. Never invent results; if a tool fails, say so.
- When a deployment is armed, poll deployment_status until it is done or failed (it takes minutes).
- Finish with a short summary of what you did, what the system reports now, and anything that is not done."""


def openai_tools(tools) -> list[dict[str, Any]]:
    return [{"type": "function", "function": {"name": t.name, "description": (t.description or "")[:4000],
                                              "parameters": t.inputSchema or {"type": "object", "properties": {}}}}
            for t in tools]


def _text(result) -> str:
    return "".join(getattr(c, "text", "") for c in result.content)


async def run(args) -> int:
    token = json.loads(Path(args.token_file).read_text())["token"]
    log = open(args.log, "a", encoding="utf-8") if args.log else None

    def emit(kind: str, **kw):
        rec = {"t": round(time.time(), 1), "kind": kind, **kw}
        print(json.dumps(rec, ensure_ascii=False)[:2000], flush=True)
        if log:
            log.write(json.dumps(rec, ensure_ascii=False) + "\n")
            log.flush()

    async with streamablehttp_client(args.mcp_url, headers={"Authorization": "Bearer " + token}, timeout=60,
                                     sse_read_timeout=3600) as (r, w, _):
        async with ClientSession(r, w) as s:
            init = await s.initialize()
            listed = (await s.list_tools()).tools
            wanted = None if args.tools == "all" else {n.strip() for n in args.tools.split(",") if n.strip()}
            tools = [t for t in listed if wanted is None or t.name in wanted]
            missing = sorted((wanted or set()) - {t.name for t in tools})
            if missing:
                emit("error", message=f"tools not offered by this Bossman: {missing}")
                return 2
            guide = init.instructions or ""
            messages: list[dict[str, Any]] = [
                {"role": "system", "content": guide + "\n\n" + RULES},
                {"role": "user", "content": args.goal},
            ]
            emit("start", model=args.model, tools=[t.name for t in tools], goal=args.goal)
            body_extra: dict[str, Any] = {} if args.thinking else {"chat_template_kwargs": {"enable_thinking": False}}
            async with httpx.AsyncClient(timeout=args.step_timeout, trust_env=False) as llm:
                for step in range(1, args.max_rounds + 1):
                    t0 = time.time()
                    resp = await llm.post(args.base_url.rstrip("/") + "/v1/chat/completions", json={
                        "model": args.model, "messages": messages, "tools": openai_tools(tools), **body_extra})
                    resp.raise_for_status()
                    data = resp.json()
                    choice = data["choices"][0]
                    msg = choice["message"]
                    emit("model", step=step, seconds=round(time.time() - t0, 1), finish=choice.get("finish_reason"),
                         content=(msg.get("content") or "")[:1500],
                         tool_calls=[{"name": c["function"]["name"], "arguments": c["function"].get("arguments")}
                                     for c in msg.get("tool_calls") or []],
                         timings=data.get("timings"))
                    messages.append({k: v for k, v in msg.items() if k in ("role", "content", "tool_calls")})
                    calls = msg.get("tool_calls") or []
                    if not calls:
                        emit("final", step=step, content=msg.get("content"))
                        return 0
                    for c in calls:
                        name = c["function"]["name"]
                        try:
                            arguments = json.loads(c["function"].get("arguments") or "{}")
                        except json.JSONDecodeError as exc:
                            out, err = f"arguments were not valid JSON: {exc}", True
                        else:
                            t1 = time.time()
                            res = await s.call_tool(name, arguments)
                            out, err = _text(res), bool(res.isError)
                            emit("tool", name=name, arguments=arguments, seconds=round(time.time() - t1, 1),
                                 error=err, result=out[:3000])
                        if len(out) > args.max_result_chars:
                            out = out[:args.max_result_chars] + f"\n…[{len(out) - args.max_result_chars} more characters cut]"
                        messages.append({"role": "tool", "tool_call_id": c.get("id", name), "content": out})
            emit("stopped", reason=f"max_rounds={args.max_rounds} reached without a final answer")
            return 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--goal", required=True)
    ap.add_argument("--tools", default="all", help="comma-separated MCP tool names, or 'all'")
    ap.add_argument("--mcp-url", default="http://localhost:8123/mcp/")
    ap.add_argument("--token-file", required=True, help='JSON file {"token": "<Bossman API token>"}')
    ap.add_argument("--base-url", required=True, help="OpenAI-compatible root (…/v1/chat/completions is appended)")
    ap.add_argument("--model", required=True)
    ap.add_argument("--thinking", action="store_true")
    ap.add_argument("--max-rounds", type=int, default=40)
    ap.add_argument("--max-result-chars", type=int, default=8000)
    ap.add_argument("--step-timeout", type=float, default=3600.0)
    ap.add_argument("--log", default="")
    return asyncio.run(run(ap.parse_args(argv)))


if __name__ == "__main__":
    sys.exit(main())
