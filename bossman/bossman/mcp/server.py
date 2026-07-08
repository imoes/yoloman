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
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from sqlalchemy.orm import selectinload

from bossman.config import Settings
from bossman.db.models import (
    Agent,
    HostEdge,
    HostGroup,
    HostGroupMember,
    Metric,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OrchestrationPlanVersion,
    OUNode,
    PlanRun,
    Service,
)
from bossman.mcp.auth import current_identity
from bossman.services import module_library
from bossman.services.agent_client import client_for
from bossman.services.catalog import CatalogCache
from bossman.services.compiler import (
    affected_agent_ids,
    compile_host_desired_state,
    is_yolo_mode,
    preview_plan_link as compiler_preview_plan_link,
)
from bossman.services.embedding_client import EmbeddingClient
from bossman.services.monitoring import (
    ServiceView,
    acknowledge_service,
    create_downtime,
    fleet_hosts as monitoring_fleet_hosts,
    fleet_summary,
    query_agent_services,
    query_problems,
    to_view,
)
from bossman.services.plan_engine import run_plan as engine_run_plan
from bossman.services.plan_loader import PlanError, load_host_vars
from bossman.services.plan_search import index_plan_catalog, search_plans as search_plans_service

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")
_TARGET_TYPES = ("ou", "host", "group", "label_selector", "global")


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
        """List every known agent: name, address, mode, last_seen, tags,
        parent (the proxy this host was discovered behind, if any — see
        docs/plan.md's monitoring-cockpit ergänzung Block F2)."""
        async with session_factory() as session:
            agents = (await session.scalars(select(Agent).order_by(Agent.name))).all()
            names_by_id = {a.id: a.name for a in agents}
        return [
            {
                "name": a.name,
                "address": a.address,
                "mode": a.mode,
                "last_seen": a.last_seen_at.isoformat() if a.last_seen_at else None,
                "tags": a.agent_metadata,
                "parent": names_by_id.get(a.parent_agent_id) if a.parent_agent_id else None,
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

    @mcp.tool()
    async def fleet_hosts() -> list[dict[str, Any]]:
        """The host-overview table: one entry per host — every directly enrolled agent and
        every satellite discovered behind a proxy — with real CPU/memory/disk values and a
        CheckMK-style worst-service-wins state rollup, in a single call."""
        async with session_factory() as session:
            hosts = await monitoring_fleet_hosts(session)
        return [
            {
                "id": str(h.id),
                "name": h.name,
                "parent": h.parent_name,
                "mode": h.mode,
                "enrollment_state": h.enrollment_state,
                "last_seen": h.last_seen_at.isoformat() if h.last_seen_at else None,
                "state_rollup": h.state_rollup,
                "cpu_load": h.cpu_load,
                "mem_used_pct": h.mem_used_pct,
                "disk_used_pct_max": h.disk_used_pct_max,
                "service_counts": h.service_counts,
            }
            for h in hosts
        ]

    # ── Starlark module library (docs/plan.md Block G8) ─────────────────
    # The translation pipeline's MCP surface: the contract, the source
    # templates, validation, and the write path into modules.d/. Tool
    # descriptions deliberately embed the FULL contract ("a skill, not a
    # one-liner") so an LLM driven through these tools needs no external
    # documentation to deliver clean code.

    @mcp.tool()
    async def module_contract() -> str:
        """The complete Starlark module authoring contract v1 — read this FIRST before
        writing or translating any module. A module is one .star file defining
        `def main(ctx, params)` that returns `{"changed": bool, "msg": str}` (optionally
        `"data": dict`), touching the system exclusively through the capability builtins
        `ctx.run(argv, mutates=False)` / `ctx.file_read` / `ctx.file_write` /
        `ctx.file_exists` / `ctx.stat` / `ctx.facts()`, honoring `ctx.check_mode`
        (dry-run: predict, never mutate), failing via `fail("msg")`, with no `load()`
        and no Python stdlib. The returned markdown contains the exact ctx API
        semantics, the check_mode discipline, a complete contract-correct example
        module, and the metadata-YAML schema submit_module expects."""
        return module_library.CONTRACT_MARKDOWN

    @mcp.tool()
    async def get_module_source(fqcn: str) -> dict[str, Any]:
        """The translation template for one Ansible module, by fully qualified
        collection name (e.g. "ansible.posix.sysctl"): its documented options/argspec
        (`doc.options` — mirror these in the metadata YAML), description, examples,
        and the ORIGINAL Python implementation (`source_py`) whose behavior your
        Starlark translation must reproduce (same parameters, same idempotency, same
        check_mode semantics). Sources are pre-dumped from the locally installed
        collections; fqcns are listed by list_module_status()."""
        return module_library.load_source(settings.module_sources_dir, fqcn)

    @mcp.tool()
    async def validate_module(star_code: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        """Validate one Starlark module against contract v1 WITHOUT storing it — use
        this to iterate until clean before submit_module. Runs the same Go validator
        the agent runtime is built from: parse, contract lint (main(ctx, params)
        signature, no load()), and a stub execution with mocked ctx builtins in both
        check_mode variants. Returns {ok, stub_ok, errors[{stage,message,line}],
        warnings, calls} — `ok` (parse+lint) is the hard gate for submission; fix
        every `errors` entry and resubmit. `calls` lists the ctx.* invocations the
        stub observed, so you can verify the module does what you intended.
        Optional `params`: sample arguments for the stub run (use realistic values
        for the module's required options)."""
        result = module_library.validate_star(settings.starlark_check_path, star_code, params)
        return result.to_dict()

    @mcp.tool()
    async def submit_module(fqcn: str, metadata_yaml: str, star_code: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        """Store one translated module in the library — THE write path that extends
        the system's vocabulary. Validates first (same hard gate as validate_module;
        a failing module is rejected, returned as {stored: false, validation}) and
        only then persists <modules_dir>/<collection>/<name>.star + .yaml. The
        metadata YAML must follow the schema in module_contract(): required keys
        name/fqcn/collection/short_description/options/writes/runtime, with
        runtime: starlark and fqcn == collection + "." + name, and its `options`
        mirroring the original module's argspec from get_module_source(). Optional
        `params`: sample arguments for the validation stub run."""
        return module_library.submit(
            settings.modules_dir, settings.starlark_check_path, fqcn, metadata_yaml, star_code, params
        )

    @mcp.tool()
    async def list_module_status() -> dict[str, Any]:
        """Translation progress of the module library, derived from the filesystem:
        {total, translated, collections: {<collection>: {total, translated,
        missing: [fqcn, ...]}}}. The `missing` lists are the work queue — pick the
        next fqcn from there, get_module_source() it, translate, validate_module()
        until ok, then submit_module(). Safe to call any time for resume."""
        return module_library.status(settings.modules_dir, settings.module_sources_dir)

    # ── Policy & Orchestration (Block L2) ────────────────────────────────
    # Read-only + a safe dry-run preview + ONE gated write tool for the
    # Policy/Orchestration layer (Block L1: OU tree, host groups,
    # orchestration plans/links, compiled desired state — see
    # services/compiler.py). The write tool (propose_orchestration_plan_link)
    # can NEVER set auto_apply=true — only a human via the REST API can.
    # A new link therefore starts pending_approval unless the global
    # YOLO-MAN switch (system_settings.yolo_mode, human-toggled via
    # PUT /api/v1/system/yolo-mode, never exposed to MCP as a write) is on,
    # in which case every link — MCP-proposed or not — activates
    # immediately. "The AI proposes; a human confirms" is enforced here by
    # what this tool CANNOT pass, not by asking the model nicely.

    async def _resolve_plan_or_raise(session: AsyncSession, plan_name: str) -> OrchestrationPlan:
        plan = await session.scalar(
            select(OrchestrationPlan).where(OrchestrationPlan.tenant_id == DEFAULT_TENANT_ID, OrchestrationPlan.name == plan_name)
        )
        if plan is None:
            raise ValueError(f"no such orchestration plan {plan_name!r}")
        return plan

    @mcp.tool()
    async def list_orchestration_plans() -> list[dict[str, Any]]:
        """List every orchestration plan (a named role/cluster/deployment bundle like
        "docker_host" or "postgres_cluster" — see get_orchestration_plan for its full
        content): name, display_name, plan_type, current_version, enabled."""
        async with session_factory() as session:
            rows = (
                await session.scalars(
                    select(OrchestrationPlan).where(OrchestrationPlan.tenant_id == DEFAULT_TENANT_ID, OrchestrationPlan.deleted_at.is_(None)).order_by(OrchestrationPlan.name)
                )
            ).all()
        return [
            {"name": p.name, "display_name": p.display_name, "plan_type": p.plan_type, "current_version": p.current_version, "enabled": p.enabled}
            for p in rows
        ]

    @mcp.tool()
    async def get_orchestration_plan(plan: str) -> dict[str, Any]:
        """Full detail for one orchestration plan by name, including its current
        version's steps/parameters/generated_monitoring — read this before proposing
        a link so you know what a host would actually get."""
        async with session_factory() as session:
            p = await _resolve_plan_or_raise(session, plan)
            version = await session.scalar(
                select(OrchestrationPlanVersion).where(OrchestrationPlanVersion.plan_id == p.id, OrchestrationPlanVersion.version == p.current_version)
            )
        return {
            "name": p.name, "display_name": p.display_name, "description": p.description,
            "plan_type": p.plan_type, "current_version": p.current_version, "enabled": p.enabled,
            "default_parameters": version.default_parameters if version else {},
            "generated_monitoring": version.generated_monitoring if version else {},
            "steps": version.steps if version else [],
        }

    @mcp.tool()
    async def list_host_groups() -> list[dict[str, Any]]:
        """List every host group (the AD-model many-to-many group object a host can
        belong to alongside its single OU placement): name, description, member count."""
        async with session_factory() as session:
            rows = (
                await session.scalars(
                    select(HostGroup).where(HostGroup.tenant_id == DEFAULT_TENANT_ID, HostGroup.deleted_at.is_(None)).order_by(HostGroup.name)
                )
            ).all()
            counts = {}
            for g in rows:
                counts[g.id] = await session.scalar(
                    select(func.count(HostGroupMember.id)).where(HostGroupMember.host_group_id == g.id)
                )
        return [{"name": g.name, "description": g.description, "member_count": counts.get(g.id, 0)} for g in rows]

    @mcp.tool()
    async def get_ou_tree() -> list[dict[str, Any]]:
        """Every OU node, flat, sorted by path (e.g. "/Germany/Munich/Prod") — a host
        lives at exactly one of these (its single AD-style placement); reconstruct the
        tree from parent_path if you need nesting, or just match on path prefix."""
        async with session_factory() as session:
            rows = (
                await session.scalars(
                    select(OUNode).where(OUNode.tenant_id == DEFAULT_TENANT_ID, OUNode.deleted_at.is_(None)).order_by(OUNode.path)
                )
            ).all()
        return [{"name": n.name, "path": n.path} for n in rows]

    @mcp.tool()
    async def get_host_desired_state(host: str) -> dict[str, Any]:
        """The compiled desired state for one host by name — orchestration roles it's
        assigned (via its OU/groups/direct links) and the monitoring checks/thresholds
        those roles generate. Compiles fresh on every call; cheap, side-effect-free
        beyond persisting the (usually unchanged) generation row."""
        async with session_factory() as session:
            agent = await session.scalar(select(Agent).where(Agent.name == host))
            if agent is None:
                raise ValueError(f"no such host {host!r}")
            result = await compile_host_desired_state(session, agent.id)
            await session.commit()
        return {"generation": result.generation, "config_hash": result.config_hash, "state": result.state}

    @mcp.tool()
    async def list_pending_orchestration_links() -> list[dict[str, Any]]:
        """The approval queue: every orchestration plan link — MCP-proposed or
        human-created — currently awaiting a human's approve/reject decision (see
        POST /api/v1/orchestration/plans/{id}/links/{id}/approve). Nothing here
        affects any host's desired state yet."""
        async with session_factory() as session:
            rows = (
                await session.scalars(
                    select(OrchestrationPlanLink).where(OrchestrationPlanLink.tenant_id == DEFAULT_TENANT_ID, OrchestrationPlanLink.status == "pending_approval").order_by(OrchestrationPlanLink.created_at)
                )
            ).all()
            out = []
            for link in rows:
                plan = await session.get(OrchestrationPlan, link.plan_id)
                out.append({
                    "link_id": str(link.id), "plan": plan.name if plan else None, "target_type": link.target_type,
                    "parameters": link.parameters, "created_by": link.created_by, "created_at": link.created_at.isoformat(),
                })
        return out

    async def _resolve_target(session: AsyncSession, target_type: str, target: str | None) -> dict[str, UUID]:
        if target_type not in _TARGET_TYPES:
            raise ValueError(f"target_type must be one of {_TARGET_TYPES}")
        if target_type == "global":
            return {}
        if target is None:
            raise ValueError(f"target_type={target_type!r} requires `target`")
        if target_type == "host":
            agent = await session.scalar(select(Agent).where(Agent.name == target))
            if agent is None:
                raise ValueError(f"no such host {target!r}")
            return {"agent_id": agent.id}
        if target_type == "ou":
            node = await session.scalar(select(OUNode).where(OUNode.tenant_id == DEFAULT_TENANT_ID, OUNode.path == target))
            if node is None:
                raise ValueError(f"no such OU {target!r}")
            return {"ou_id": node.id}
        if target_type == "group":
            group = await session.scalar(select(HostGroup).where(HostGroup.tenant_id == DEFAULT_TENANT_ID, HostGroup.name == target))
            if group is None:
                raise ValueError(f"no such host group {target!r}")
            return {"host_group_id": group.id}
        raise ValueError(f"target_type {target_type!r} is not resolvable")

    @mcp.tool()
    async def preview_orchestration_plan_link(
        plan: str, target_type: str, target: str | None = None, parameters: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        """Safe, read-only "what would happen" preview for a NOT-YET-CREATED plan
        link — blast radius (how many hosts) and a sample before/after monitoring
        diff for one affected host. Writes nothing. target_type is one of
        ou/host/group/global; target is the OU path / host name / group name
        (omit for global). Always call this before propose_orchestration_plan_link
        so you can explain the impact to the user."""
        async with session_factory() as session:
            plan_obj = await _resolve_plan_or_raise(session, plan)
            ids = await _resolve_target(session, target_type, target)
            result = await compiler_preview_plan_link(
                session, DEFAULT_TENANT_ID, plan_obj.id, target_type, parameters=parameters or {}, **ids
            )
        if result is None:
            raise ValueError(f"no such orchestration plan {plan!r}")
        return result

    @mcp.tool()
    async def propose_orchestration_plan_link(
        plan: str, target_type: str, target: str | None = None, parameters: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        """Propose linking a plan to a scope (OU/host/group/global) — the ONE gated
        write tool in this section. This NEVER activates immediately: it always
        creates the link with require_approval=true and auto_apply=false, so it
        starts status="pending_approval" and has zero effect on any host until a
        human approves it via the REST API (unless the global YOLO-MAN switch is
        already on, which only a human can enable). Call preview_orchestration_plan_link
        first and show the user the blast radius before proposing."""
        ids = {}
        requested_by = current_identity.get() or "mcp-facade"
        async with session_factory() as session:
            plan_obj = await _resolve_plan_or_raise(session, plan)
            ids = await _resolve_target(session, target_type, target)
            yolo = await is_yolo_mode(session)
            status = "active" if yolo else "pending_approval"
            link = OrchestrationPlanLink(
                tenant_id=DEFAULT_TENANT_ID, plan_id=plan_obj.id, target_type=target_type,
                parameters=parameters or {}, require_approval=True, auto_apply=False,
                status=status, created_by=requested_by, **ids,
            )
            session.add(link)
            await session.commit()
            if status == "active":
                for agent_id in await affected_agent_ids(session, target_type, tenant_id=DEFAULT_TENANT_ID, **ids):
                    await compile_host_desired_state(session, agent_id)
                await session.commit()
        return {"link_id": str(link.id), "plan": plan, "status": status}

    return mcp
