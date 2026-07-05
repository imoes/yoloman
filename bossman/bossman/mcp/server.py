"""The MCP facade for Bossman (see docs/plan.md's Bossman plan, sections
B.6/B.8): the AI-facing tool surface, deliberately kept at plan+host
granularity only — list_hosts, host_status, host_relationships,
list_plans, get_catalog, run_plan, get_plan_run — never the ~52 granular
module tools a standalone node agent exposes directly. That granularity
was needed for the standalone-node-agent case the plan explicitly carved
out as this facade's non-goal ("per MCP macht keinen Sinn nur wenn der
Client als standalone läuft").

build_mcp_server is a factory, not a module-level singleton: it closes
over a specific session_factory/settings/catalog_cache/client_factory so
tests can construct an instance against a throwaway database and a fake
AgentClient, the same test-seam discipline every other services/ module
in this project already follows.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID

from mcp.server.fastmcp import FastMCP
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from sqlalchemy.orm import selectinload

from bossman.config import Settings
from bossman.db.models import Agent, HostEdge, Metric, PlanRun, Service
from bossman.mcp.auth import current_identity
from bossman.services.agent_client import client_for
from bossman.services.catalog import CatalogCache
from bossman.services.embedding_client import EmbeddingClient
from bossman.services.monitoring import (
    ServiceView,
    acknowledge_service,
    create_downtime,
    fleet_summary,
    query_agent_services,
    query_problems,
    to_view,
)
from bossman.services.plan_engine import run_plan as engine_run_plan
from bossman.services.plan_loader import PlanError, load_host_vars
from bossman.services.plan_search import index_plan_catalog, search_plans as search_plans_service


def _service_view_dict(view: ServiceView) -> dict[str, Any]:
    s = view.service
    return {
        "service_id": str(s.id),
        "host": view.agent_name,
        "name": s.name,
        "state": s.state,
        "value": s.value,
        "output": s.output,
        "acknowledged": s.acknowledged,
        "in_downtime": view.in_downtime,
        "last_state_change": s.last_state_change.isoformat(),
    }


def build_mcp_server(
    session_factory: async_sessionmaker[AsyncSession],
    settings: Settings,
    catalog_cache: CatalogCache,
    embedding_client: EmbeddingClient,
    client_factory=client_for,
) -> FastMCP:
    # streamable_http_path="/" because this server is itself mounted at
    # /mcp in bossman/main.py — FastMCP's own default internal path is
    # also "/mcp", which would double up to /mcp/mcp and 404 every real
    # request (caught by an actual MCP client run against a live server,
    # not by any in-process test, which never asked FastMCP for its own
    # ASGI app).
    mcp = FastMCP(name="bossman", instructions=catalog_cache.catalog_markdown, streamable_http_path="/")

    @mcp.tool()
    async def list_hosts() -> list[dict[str, Any]]:
        """List every known agent: name, address, mode, last_seen, tags."""
        async with session_factory() as session:
            agents = (await session.scalars(select(Agent).order_by(Agent.name))).all()
        return [
            {
                "name": a.name,
                "address": a.address,
                "mode": a.mode,
                "last_seen": a.last_seen_at.isoformat() if a.last_seen_at else None,
                "tags": a.agent_metadata,
            }
            for a in agents
        ]

    @mcp.tool()
    async def host_status(host: str) -> dict[str, Any]:
        """Facts, latest metric snapshot, and latest plan run for one host (by name)."""
        async with session_factory() as session:
            agent = await session.scalar(select(Agent).where(Agent.name == host))
            if agent is None:
                raise ValueError(f"no such host {host!r}")
            recent_metrics = (
                await session.scalars(
                    select(Metric).where(Metric.agent_id == agent.id).order_by(Metric.time.desc()).limit(20)
                )
            ).all()
            latest_run = await session.scalar(
                select(PlanRun).where(PlanRun.agent_id == agent.id).order_by(PlanRun.started_at.desc()).limit(1)
            )

        return {
            "name": agent.name,
            "address": agent.address,
            "mode": agent.mode,
            "enrollment_state": agent.enrollment_state,
            "last_seen": agent.last_seen_at.isoformat() if agent.last_seen_at else None,
            "recent_metrics": [
                {"metric": m.metric, "value": m.value, "time": m.time.isoformat()} for m in recent_metrics
            ],
            "last_plan_run": (
                {"plan_run_id": str(latest_run.id), "plan_name": latest_run.plan_name, "status": latest_run.status}
                if latest_run is not None
                else None
            ),
        }

    @mcp.tool()
    async def host_relationships(host: str, depth: int = 1) -> dict[str, Any]:
        """Connection edges originating from one host (by name). v1 supports depth=1 only —
        a direct "who does this host talk to" view; multi-hop traversal is a documented future
        extension (see docs/plan.md), not built speculatively here."""
        async with session_factory() as session:
            agent = await session.scalar(select(Agent).where(Agent.name == host))
            if agent is None:
                raise ValueError(f"no such host {host!r}")
            edges = (await session.scalars(select(HostEdge).where(HostEdge.src_agent_id == agent.id))).all()

        return {
            "edges": [
                {
                    "dst_addr": str(e.dst_addr),
                    "dst_port": e.dst_port,
                    "comm": e.src_comm,
                    "event_count": e.event_count,
                    "latency_ms_p50": e.latency_ms_p50,
                }
                for e in edges
            ]
        }

    @mcp.tool()
    async def list_plans() -> list[dict[str, Any]]:
        """List every available plan: name, description, params."""
        return catalog_cache.list_json

    @mcp.tool()
    async def search_plans(query: str, top_k: int = 5) -> list[dict[str, Any]]:
        """Embedding-based search over the plan catalog — an alternative to list_plans/
        get_catalog for finding the few relevant plans by natural-language intent (e.g. "install
        docker") once the catalog has grown too large to scan in full. Returns [{name,
        description, similarity}], most relevant first; an empty list means nothing matched
        closely enough to suggest, not an error."""
        async with session_factory() as session:
            await index_plan_catalog(session, embedding_client, catalog_cache.plans)
            results = await search_plans_service(
                session, embedding_client, query=query, top_k=top_k, threshold=settings.plan_search_threshold
            )
        return [{"name": r.name, "description": r.description, "similarity": r.similarity} for r in results]

    @mcp.tool()
    async def get_catalog() -> str:
        """The static, cached plan-catalog text — byte-identical across calls until an
        operator explicitly reloads it (POST /api/v1/plans/reload). Meant to be pasted into an
        LLM client's own system prompt with cache_control so the plan catalog doesn't cost
        input tokens on every turn — that's the whole point of it being static (see
        docs/plan.md's prompt-caching design)."""
        return catalog_cache.catalog_markdown

    @mcp.tool()
    async def run_plan(plan: str, host: str, params: dict[str, Any] | None = None, dry_run: bool = False) -> dict[str, Any]:
        """Run a named plan against a host by name — "take plan X, run it against host Y"."""
        plan_obj = catalog_cache.get(plan)
        if plan_obj is None:
            raise ValueError(f"no such plan {plan!r}")

        requested_by = current_identity.get() or "mcp-facade"

        async with session_factory() as session:
            agent = await session.scalar(select(Agent).where(Agent.name == host))
            if agent is None:
                raise ValueError(f"no such host {host!r}")
            if not agent.address:
                raise ValueError(f"host {host!r} has no reachable address")

            host_vars = load_host_vars(settings.plans_dir, agent.name)
            client = client_factory(agent, settings)
            try:
                plan_run = await engine_run_plan(
                    session,
                    agent,
                    plan_obj,
                    host_vars=host_vars,
                    explicit_params=params or {},
                    dry_run=dry_run,
                    client=client,
                    requested_by=requested_by,
                )
            except PlanError as exc:
                raise ValueError(str(exc)) from exc

        return {"plan_run_id": str(plan_run.id), "status": plan_run.status}

    @mcp.tool()
    async def get_plan_run(plan_run_id: str) -> dict[str, Any]:
        """Full step-by-step detail for one plan run, by its id."""
        try:
            run_id = UUID(plan_run_id)
        except ValueError as exc:
            raise ValueError(f"{plan_run_id!r} is not a valid plan run id") from exc

        async with session_factory() as session:
            run = await session.get(PlanRun, run_id, options=[selectinload(PlanRun.steps)])
            if run is None:
                raise ValueError(f"no such plan run {plan_run_id}")
            steps = sorted(run.steps, key=lambda s: s.step_index)

        return {
            "plan_run_id": str(run.id),
            "plan_name": run.plan_name,
            "status": run.status,
            "params": run.params,
            "dry_run": run.dry_run,
            "started_at": run.started_at.isoformat(),
            "finished_at": run.finished_at.isoformat() if run.finished_at else None,
            "steps": [
                {
                    "step_name": s.step_name,
                    "module": s.module,
                    "changed": s.changed,
                    "http_status": s.http_status,
                    "error": s.error,
                }
                for s in steps
            ],
        }

    @mcp.tool()
    async def list_problems(state: str | None = None, acknowledged: bool | None = None) -> list[dict[str, Any]]:
        """List every active fleet problem — a non-OK service that isn't currently covered by a
        downtime — the CheckMK-style "unbehandelte Probleme" view an admin (human or AI) should
        triage first. Optionally filter by state (WARN|CRIT|UNKNOWN) and/or acknowledged."""
        async with session_factory() as session:
            views = await query_problems(session, state=state, acknowledged=acknowledged)
        return [_service_view_dict(v) for v in views]

    @mcp.tool()
    async def host_services(host: str) -> list[dict[str, Any]]:
        """Every monitored service for one host (by name), with its current state — the
        CheckMK-style drill-down from a host to its services."""
        async with session_factory() as session:
            agent = await session.scalar(select(Agent).where(Agent.name == host))
            if agent is None:
                raise ValueError(f"no such host {host!r}")
            views = await query_agent_services(session, agent.id)
        return [_service_view_dict(v) for v in views or []]

    @mcp.tool()
    async def acknowledge_problem(host: str, service: str, comment: str = "") -> dict[str, Any]:
        """Acknowledge one host's service problem — "we know, don't page anyone" (CheckMK's own
        acknowledge semantics). Stays suppressed until the service's state changes again."""
        requested_by = current_identity.get() or "mcp-facade"
        async with session_factory() as session:
            agent = await session.scalar(select(Agent).where(Agent.name == host))
            if agent is None:
                raise ValueError(f"no such host {host!r}")
            svc = await session.scalar(select(Service).where(Service.agent_id == agent.id, Service.name == service))
            if svc is None:
                raise ValueError(f"no such service {service!r} on host {host!r}")
            updated = await acknowledge_service(session, svc.id, comment, requested_by)
            view = await to_view(session, updated)
        return _service_view_dict(view)

    @mcp.tool()
    async def schedule_downtime(host: str, minutes: int, service: str | None = None, comment: str = "") -> dict[str, Any]:
        """Schedule a maintenance downtime window starting now for `minutes` minutes — for one
        named service, or the whole host if service is omitted (CheckMK's host-vs-service
        downtime distinction). Problems covered by an active downtime are excluded from
        list_problems, since a downtime means "expected, don't alert"."""
        requested_by = current_identity.get() or "mcp-facade"
        now = datetime.now(timezone.utc)
        async with session_factory() as session:
            agent = await session.scalar(select(Agent).where(Agent.name == host))
            if agent is None:
                raise ValueError(f"no such host {host!r}")
            try:
                downtime = await create_downtime(
                    session,
                    agent_id=agent.id,
                    service_name=service,
                    starts_at=now,
                    ends_at=now + timedelta(minutes=minutes),
                    comment=comment,
                    created_by=requested_by,
                )
            except ValueError as exc:
                raise ValueError(str(exc)) from exc
        return {
            "downtime_id": str(downtime.id),
            "host": host,
            "service_name": downtime.service_name,
            "starts_at": downtime.starts_at.isoformat(),
            "ends_at": downtime.ends_at.isoformat(),
        }

    @mcp.tool()
    async def fleet_health() -> dict[str, Any]:
        """Fleet-wide counters: hosts by enrollment state, services by monitoring state, and how
        many are genuinely open problems (non-OK, unacknowledged, not in downtime) needing
        attention — the number that should actually draw a human's or an AI's focus first."""
        async with session_factory() as session:
            summary = await fleet_summary(session)
        return {
            "hosts_total": summary.hosts_total,
            "hosts_by_enrollment": summary.hosts_by_enrollment,
            "services_by_state": summary.services_by_state,
            "open_problems": summary.open_problems,
        }

    return mcp
