"""Blast-radius / what-if (killer-feature increment c) — the guardrail that
makes an AI-driven (or human) apply trustworthy: BEFORE writing, predict both
what changes AND what it could break.

Two halves, both from live state:
- WHAT CHANGES: the agent's own plan (state/plan) over the proposed resources —
  the per-file/per-key diff, no write.
- WHAT BREAKS: the inbound dependency edges from the topology (who connects TO
  this host) — the services/hosts that could be affected if this host's config
  changes force a reload/restart.

Read-only; the caller decides whether to proceed to apply.
"""
from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, HostEdge


async def compute_blast_radius(
    session: AsyncSession,
    agent: Agent,
    client_factory,
    settings,
    resources: list[dict[str, Any]],
) -> dict[str, Any]:
    """Impact of applying `resources` to `agent`: the change diff + the inbound
    dependents that could be affected + a compact risk summary."""
    result: dict[str, Any] = {"agent": {"id": str(agent.id), "name": agent.name}, "errors": {}}

    # ── WHAT CHANGES — the agent's plan (no write) ──────────────────────────
    changed_paths: list[str] = []
    try:
        raw = await client_factory(agent, settings).state_plan({"resources": resources})
        plan = raw.get("plan") if isinstance(raw.get("plan"), dict) else raw
        changes = plan.get("changes") or []
        changed_paths = [c.get("path") for c in changes if isinstance(c, dict) and c.get("path")]
        result["plan"] = {
            "changed_count": plan.get("changed_count", len(changes)),
            "changes": [
                {"path": c.get("path"), "type": c.get("type"), "action": c.get("action"),
                 "changed": c.get("changed")}
                for c in changes if isinstance(c, dict)
            ],
        }
    except Exception as exc:  # noqa: BLE001 — best-effort; still report dependents
        result["errors"]["plan"] = str(exc)[:200]
        changed_paths = [r.get("path") for r in resources if isinstance(r, dict) and r.get("path")]
    result["changed_paths"] = sorted(set(changed_paths))

    # ── WHAT BREAKS — inbound dependents (who connects TO this host) ────────
    try:
        edges = (await session.scalars(
            select(HostEdge).where(HostEdge.dst_agent_id == agent.id)
        )).all()
        srcs = sorted({str(e.src_agent_id) for e in edges if e.src_agent_id})
        result["dependents"] = {
            "connection_count": len(edges),
            "source_host_count": len(srcs),
            "top": [
                {"src_agent_id": str(e.src_agent_id) if e.src_agent_id else None,
                 "via_comm": e.src_comm, "dst_port": e.dst_port, "event_count": e.event_count}
                for e in sorted(edges, key=lambda x: x.event_count or 0, reverse=True)[:25]
            ],
        }
        dep_conns, dep_hosts = len(edges), len(srcs)
    except Exception as exc:  # noqa: BLE001
        result["errors"]["dependents"] = str(exc)[:200]
        dep_conns = dep_hosts = 0

    # ── risk summary ────────────────────────────────────────────────────────
    n_files = len(result["changed_paths"])
    n_changes = result.get("plan", {}).get("changed_count", n_files)
    result["summary"] = (
        f"{n_changes} change(s) across {n_files} file(s); "
        f"{dep_conns} inbound dependent connection(s) from {dep_hosts} host(s) could be affected."
        + (" No changes — safe." if n_changes == 0 else "")
    )
    result["risk"] = "none" if n_changes == 0 else ("elevated" if dep_hosts else "low")
    return result
