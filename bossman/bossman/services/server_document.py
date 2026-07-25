"""The server-document — the AI knowledge substrate (killer-feature increment d).

Composes a host's COMPLETE state into one queryable JSON so the LLM/MCP can
reason with full, always-fresh context (config + desired + change history +
dependency topology). This is what the user asked for: "the AI must be able to
retrieve all config information for desired state" — a retrieval, not a UI
change (the desired-state tab is untouched). Everything else in the killer
feature (self-documenting NL Q&A, blast-radius) is built on this.

Read-only + best-effort: each section is optional (`include`) and isolated in
try/except, so an unreachable agent or one bad section still yields whatever
context IS available (an LLM wants partial context, not a 500).
"""
from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, AgentObservedState, HostEdge
from bossman.services.compiler import _build_desired_state

ALL_SECTIONS = ("config", "desired", "generations", "topology")


async def build_server_document(
    session: AsyncSession,
    agent: Agent,
    client_factory,
    settings,
    include: set[str],
) -> dict[str, Any]:
    """One host as a complete document. `include` selects sections (subset of
    ALL_SECTIONS). `errors` maps a section name to why it's missing."""
    doc: dict[str, Any] = {
        "agent": {"id": str(agent.id), "name": agent.name},
        "included": sorted(s for s in include if s in ALL_SECTIONS),
        "errors": {},
    }

    if "config" in include:
        # The whole server config, observed via each file's codec — served from
        # the poller-refreshed cache (no live round-trip). This is the server-
        # as-a-document read the desired-state tab also shows.
        cached = await session.get(AgentObservedState, agent.id)
        doc["config"] = {
            "observed": cached.observed if cached else None,
            "cached_at": cached.updated_at.isoformat() if cached and cached.updated_at else None,
        }

    if "desired" in include:
        try:
            state, explain = await _build_desired_state(session, agent)
            doc["desired"] = {"state": state, "explain": explain}
        except Exception as exc:  # noqa: BLE001 — best-effort section
            doc["errors"]["desired"] = str(exc)[:200]

    if "generations" in include:
        # Change history (rollback points) — a live agent call, best-effort.
        try:
            doc["generations"] = await client_factory(agent, settings).state_generations()
        except Exception as exc:  # noqa: BLE001
            doc["errors"]["generations"] = str(exc)[:200]

    if "topology" in include:
        try:
            edges = (await session.scalars(
                select(HostEdge).where(HostEdge.src_agent_id == agent.id)
            )).all()
            doc["topology"] = {"edges": [
                {
                    "src_comm": e.src_comm,
                    "dst_addr": str(e.dst_addr),
                    "dst_port": e.dst_port,
                    "dst_agent_id": str(e.dst_agent_id) if e.dst_agent_id else None,
                    "event_count": e.event_count,
                    "latency_ms_p50": e.latency_ms_p50,
                }
                for e in edges
            ]}
        except Exception as exc:  # noqa: BLE001
            doc["errors"]["topology"] = str(exc)[:200]

    return doc
