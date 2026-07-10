"""Block K3 — fleet tools the chat AI can call (agentic loop).

Exposes a curated, read-only set of Bossman fleet operations as OpenAI
function-calling tool definitions plus an in-process async executor. The
agentic loop (chat_agent.py) hands these to a tool-capable backend, runs the
tools it requests against the DB, and feeds the results back — so the AI can
answer with LIVE fleet data and render widgets from it (e.g. a donut of
enrolled vs pending hosts).

v1 is read-only on purpose: mutating fleet actions (run_plan, service control)
go through the existing, separately-audited MCP/REST paths and are added here
only deliberately.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent

_ONLINE_WINDOW = timedelta(minutes=5)


# OpenAI function-calling tool definitions handed to the model.
TOOL_DEFS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "list_hosts",
            "description": "List every host (agent) in the fleet with its mode, enrollment state, and whether it is online (seen in the last 5 minutes).",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "fleet_health",
            "description": "Summary counts of the fleet: total hosts, how many are enrolled, and how many are currently online vs offline.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
]

TOOL_NAMES = {t["function"]["name"] for t in TOOL_DEFS}


def _online(agent: Agent, now: datetime) -> bool:
    return bool(agent.last_seen_at and agent.last_seen_at >= now - _ONLINE_WINDOW)


async def execute_tool(session: AsyncSession, name: str, args: dict[str, Any]) -> dict[str, Any]:
    """Run one fleet tool in-process and return a JSON-serializable result.
    Unknown tools return an error dict (the model sees it and can recover)."""
    now = datetime.now(timezone.utc)
    if name == "list_hosts":
        agents = (await session.scalars(select(Agent).order_by(Agent.name))).all()
        return {
            "hosts": [
                {
                    "name": a.name,
                    "mode": a.mode,
                    "enrollment_state": a.enrollment_state,
                    "online": _online(a, now),
                }
                for a in agents
            ]
        }
    if name == "fleet_health":
        agents = (await session.scalars(select(Agent))).all()
        total = len(agents)
        enrolled = sum(1 for a in agents if a.enrollment_state == "enrolled")
        online = sum(1 for a in agents if _online(a, now))
        return {"total": total, "enrolled": enrolled, "online": online, "offline": total - online}
    return {"error": f"unknown tool {name!r}"}
