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
import json
from pathlib import Path
from typing import Any
from uuid import UUID

from mcp.server.fastmcp import FastMCP
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from sqlalchemy.orm import selectinload

from bossman.config import Settings
from bossman.db.models import (
    Agent,
    CheckRule,
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
from bossman.services import checks_library, module_library
from bossman.services.ops_guide import BOSSMAN_GUIDE
from bossman.services.agent_client import AgentClientError, client_for
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
        # F-17: what the value is graded against, so an AI can reason about the
        # problem (and whether the threshold, not the host, is the issue).
        "warn_threshold": view.warn_threshold,
        "crit_threshold": view.crit_threshold,
        "comparison": view.comparison,
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
    # Instructions every MCP client sees on connect: the DevOps skill (how to
    # drive Bossman, which tool for which task) THEN the known-plans catalog.
    _instructions = BOSSMAN_GUIDE + "\n\n---\n\n## Known plans (catalog)\n\n" + (catalog_cache.catalog_markdown or "")
    mcp = FastMCP(name="bossman", instructions=_instructions, streamable_http_path="/")

    @mcp.tool()
    async def web_search(query: str, limit: int = 6) -> list[dict[str, str]]:
        """Search the web via the internal SearXNG metasearch engine. Returns
        ranked hits as {title, url, content}. Use it to find official software
        documentation, man pages, and configuration references — then fetch_url
        to read a page. Backs the package-doc verification of config roles."""
        from bossman.services.websearch import SearxngClient

        results = await SearxngClient(settings.searxng_base_url).search(query, limit=limit)
        return [r.to_dict() for r in results]

    @mcp.tool()
    async def bossman_guide() -> str:
        """START HERE. Returns the Bossman operator skill: how to run day-2 fleet
        operations through these tools — the mental model (agentic ops OS; read
        first; writes are dry-run + human-gated) and, per DevOps task, EXACTLY which
        tool to call: inspect a host/fleet, configure ONE host (set_host_config) vs
        MANY via a POLICY linked to an OU/Site/group, monitoring & thresholds,
        playbooks/runbooks, provisioning & packages (qualify_package), module/check
        authoring, rehearsal, and the generic resource lifecycle. Same text as the
        server `instructions`. Call this (or search_help) whenever unsure."""
        return BOSSMAN_GUIDE

    @mcp.tool()
    async def search_help(query: str, limit: int = 5) -> list[dict[str, Any]]:
        """Search Bossman's own documentation (README + docs/) — the source of
        truth for how the product works. Returns ranked sections {source, heading,
        text}. Use this WHENEVER you're unsure how to do something in Bossman
        (before guessing): e.g. "how do policies work", "config precedence",
        "create a runbook", "PXE provisioning". Complements bossman_guide (the
        task→tool map) with the full prose docs."""
        from bossman.services import help as help_svc

        return help_svc.search_help(settings.help_root, query, limit=limit)

    @mcp.tool()
    async def fetch_url(url: str, max_chars: int = 12000) -> str:
        """Fetch a URL and return its readable plain text (HTML stripped),
        truncated to max_chars. Pair with web_search to read documentation."""
        from bossman.services.websearch import SearxngClient

        return await SearxngClient(settings.searxng_base_url).fetch(url, max_chars=max_chars)

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
    async def fleet_search(query: str, per_host: int = 20) -> dict[str, Any]:
        """Search the WHOLE fleet's desired state in one call — the fastest way to
        analyse the fleet. Scans every host's compiled desired_state document
        (config keys/values, variables, host tags, Ansible facts, applied checks/
        roles/thresholds) and returns the hosts that match, with the matching
        leaves.

        `query` is a plain substring matched against each leaf's "path value", or
        a `key=value` form for precision (path contains key AND value contains
        value). Examples:
          - "nginx"                 → any host whose desired state mentions nginx
          - "os.family=Debian"      → hosts whose facts say Debian
          - "timezone=Europe"       → hosts with a Europe timezone variable
          - "role=web"              → hosts that got the web role
          - "config./etc/ntp.conf"  → hosts managing that file
        Returns {query, host_count, hosts:[{host, generation, match_count,
        matches:[{path,value}]}]}, hosts sorted by match_count desc."""
        from bossman.services.fleet_search import fleet_search as _fleet_search

        async with session_factory() as session:
            return await _fleet_search(session, query, per_host=per_host)

    @mcp.tool()
    async def lint_policies() -> dict[str, Any]:
        """Static-analyse the whole policy tree and report problems: config
        policies linked to nothing or setting no values, thresholds with no
        warn/crit, and — most useful — conditions whose tag/fact/variable/label
        key NO host currently has (so the rule matches nothing right now, the
        "I set it but nothing happened" trap). Read-only. Returns
        {finding_count, findings:[{severity, kind, subject, detail}]}."""
        from bossman.services.policy_lint import lint_policies as _lint

        async with session_factory() as session:
            return await _lint(session)

    @mcp.tool()
    async def capability_match(host: str) -> dict[str, Any]:
        """For a host, list what each of its unmet service requirements needs and WHO in the inventory
        provides it — the deterministic Lego matcher (same logic as the REST /capabilities/match and the
        Blueprint editor). Returns, per open requirement: the capability + accepted backends, the matching
        provider hosts (address/port) with a proposed field wiring, and — when nothing provides it yet —
        the catalog role a NEW server would need. No LLM: pure inventory set-logic over host_capabilities.
        """
        from bossman.services import capabilities as C

        async with session_factory() as session:
            agent = await session.scalar(select(Agent).where(Agent.name == host))
            if agent is None:
                raise ValueError(f"no such host {host!r}")
            consumer_addr = C._agent_address(agent)
            reqs = await C.open_requirements(session, agent.id)
            out: list[dict[str, Any]] = []
            for req in reqs:
                detail = req.detail or {}
                backends = detail.get("backends") or ([req.backend] if req.backend else [])
                found = await C.find_providers(session, settings, req.capability, backends,
                                               tenant_id=agent.tenant_id, exclude_agent=agent.id)
                entry: dict[str, Any] = {
                    "capability": req.capability, "backends": backends,
                    "providers": [{"host": p["hostname"], "address": p["address"], "backend": p["backend"],
                                   "port": p["port"],
                                   "wiring": C.propose_wiring(detail, p, consumer_address=consumer_addr)}
                                  for p in found],
                }
                if not found:
                    entry["candidate_roles"] = C.roles_providing(
                        settings, req.capability, backends[0] if backends else None)
                out.append(entry)
        return {"host": host, "requirements": out}

    async def _addressed_agent_or_raise(session: AsyncSession, host: str) -> Agent:
        agent = await session.scalar(select(Agent).where(Agent.name == host))
        if agent is None:
            raise ValueError(f"no such host {host!r}")
        if not agent.address:
            raise ValueError(f"host {host!r} has no reachable address (satellite/unenrolled)")
        return agent

    @mcp.tool()
    async def list_agent_tools(host: str) -> list[dict[str, Any]]:
        """Router: list the tools one managed agent currently exposes
        ([{name, kind, writes}]), by host name. Bossman is a gateway — use
        list_hosts to see the fleet of managed servers, this to discover a
        given server's tools, then call_agent_tool to invoke one. Write tools
        appear only when that agent's write gate is open."""
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
        try:
            return await client.list_tools()
        except AgentClientError as exc:
            raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def call_agent_tool(
        host: str, tool: str, params: dict[str, Any] | None = None, dry_run: bool = False
    ) -> dict[str, Any]:
        """Router: invoke one tool on a managed agent by host name, proxied
        through Bossman to the agent's own tool endpoint. `params` are the
        tool's parameters; `dry_run=true` is forwarded so write modules run in
        check_mode. The agent's write gate + ACL + audit are the enforcement
        point — a read-only agent rejecting a write tool raises the agent's
        error. Discover tools first with list_agent_tools."""
        body = dict(params or {})
        if dry_run:
            body["dry_run"] = True
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
        try:
            return await client.call_tool(tool, body)
        except AgentClientError as exc:
            raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def host_status(host: str) -> dict[str, Any]:
        """A quick health snapshot of ONE host (by name): its facts (OS, kernel,
        IPs), the latest metric sample (cpu/mem/disk/load), and its most recent
        plan run. The fast "how is this box doing?" read — start here before
        set_host_config / run_runbook. For deeper triage use diagnose_host,
        host_services (monitoring), get_host_logs, or get_server_document."""
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
    async def get_server_document(host: str, include: str = "config,desired,generations,topology") -> dict[str, Any]:
        """The COMPLETE server-document for one host (by name) as one JSON — the
        AI's full-context read for reasoning about a server: observed config
        (every file via its codec), desired state, change generations, and the
        dependency topology. `include` selects sections (config,desired,
        generations,topology). Use this to answer "why is X configured this way,
        what is the desired vs observed state, what changed, what does it talk
        to" grounded in live state instead of guessing."""
        from bossman.services.server_document import ALL_SECTIONS, build_server_document
        inc = {p.strip() for p in include.split(",") if p.strip()} or set(ALL_SECTIONS)
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await build_server_document(session, agent, client_factory, settings, inc)

    @mcp.tool()
    async def explain_server(host: str, question: str = "") -> dict[str, Any]:
        """Self-documenting infra: the LLM documents a host (no question) or
        answers a question about it, grounded STRICTLY in its live state
        document — always-current, never invented. Use for "document this
        server", "why is X configured this way", "what changed", "what does it
        depend on". Built on get_server_document."""
        from bossman.services.chat_client import chat_client_for
        from bossman.services.server_narrative import explain_server as _explain
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await _explain(session, agent, client_factory, settings,
                                  chat=chat_client_for(settings), question=(question or None))

    @mcp.tool()
    async def blast_radius(host: str, resources: list[dict[str, Any]]) -> dict[str, Any]:
        """What-if guardrail: predict the effect of applying `resources` to a host
        (by name) BEFORE writing — the change diff (state/plan) + the inbound
        dependents that could be affected (from topology) + a risk summary. Call
        this before an autonomous apply to check blast radius."""
        from bossman.services.blast_radius import compute_blast_radius
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await compute_blast_radius(session, agent, client_factory, settings, resources)

    @mcp.tool()
    async def export_server_spec(host: str) -> dict[str, Any]:
        """Reproducibility: capture a running host (by name) as a PORTABLE spec —
        its structured config as re-appliable resources — for clone /
        golden-from-running / DR. Read-only. Materializing the spec onto a target
        is a separate, human-gated (dry-run-first) API step."""
        from bossman.services.server_reproduce import export_server_spec as _export
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await _export(session, agent, client_factory, settings)

    # ── Helm / Kubernetes: the AI-autonomous k8s deploy surface ─────────────
    # find chart → inspect values → preview → install → verify → rollback, all
    # via the host's helm CLI. host = the agent whose host has helm + kubeconfig.
    @mcp.tool()
    async def helm_charts(host: str, query: str = "") -> dict[str, Any]:
        """Available Helm charts to deploy (helm search repo) on a host's configured repos."""
        from bossman.services import helm_app
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await helm_app.search_charts(agent, client_factory, settings, query=query)

    @mcp.tool()
    async def helm_chart_values(host: str, chart: str) -> dict[str, Any]:
        """A chart's default values (helm show values) — inspect before deploying."""
        from bossman.services import helm_app
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await helm_app.chart_values(agent, client_factory, settings, chart=chart)

    @mcp.tool()
    async def helm_render(host: str, name: str, chart: str, values_yaml: str = "", namespace: str = "default") -> dict[str, Any]:
        """Preview the manifests a release would produce (helm template) — no cluster write."""
        from bossman.services import helm_app
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await helm_app.render_release(agent, client_factory, settings, name=name, chart=chart, values_yaml=values_yaml, namespace=namespace)

    @mcp.tool()
    async def helm_releases(host: str) -> dict[str, Any]:
        """Deployed Helm releases on the cluster (helm list -A) — what k8s apps are running."""
        from bossman.services import helm_app
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await helm_app.list_releases(agent, client_factory, settings)

    @mcp.tool()
    async def helm_install(host: str, name: str, chart: str, values_yaml: str = "", namespace: str = "default") -> dict[str, Any]:
        """Deploy or upgrade a release (helm upgrade --install). Mutates the cluster —
        preview with helm_render first for a complex deploy."""
        from bossman.services import helm_app
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await helm_app.install_release(agent, client_factory, settings, name=name, chart=chart, values_yaml=values_yaml, namespace=namespace)

    @mcp.tool()
    async def helm_rollback(host: str, name: str, revision: int = 0, namespace: str = "default") -> dict[str, Any]:
        """Roll a release back to a previous revision (0 = last)."""
        from bossman.services import helm_app
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await helm_app.rollback_release(agent, client_factory, settings, name=name, revision=(revision or None), namespace=namespace)

    @mcp.tool()
    async def helm_uninstall(host: str, name: str, namespace: str = "default") -> dict[str, Any]:
        """Remove a release from the cluster (helm uninstall)."""
        from bossman.services import helm_app
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await helm_app.uninstall_release(agent, client_factory, settings, name=name, namespace=namespace)

    # --- Systems / rehearsal plane (clone-a-prod-system, AI-autonomous) -------

    async def _system_by_name_or_raise(session: AsyncSession, name: str):
        from bossman.db.models import System
        s = (await session.scalars(select(System).where(System.name == name))).first()
        if s is None:
            raise ValueError(f"no such system: {name!r} (use system_list)")
        return s

    @mcp.tool()
    async def system_propose(host: str, name: str = "") -> dict[str, Any]:
        """Propose a System (apps + wiring, the unit above a host) from a seed
        host's live state — docker/k8s/native members. Read-only; persist with
        system_create."""
        from bossman.services import system_discover
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await system_discover.propose_system(session, agent, client_factory, settings, name=name or None)

    @mcp.tool()
    async def system_create(name: str, seed_host: str = "", members: list[dict[str, Any]] | None = None,
                            edges: list[dict[str, Any]] | None = None, description: str = "") -> dict[str, Any]:
        """Persist a System (typically a confirmed system_propose result)."""
        from bossman.db.models import System, SystemMember
        _CORE = {"target", "app", "role_in_system"}
        async with session_factory() as session:
            if (await session.scalars(select(System).where(System.name == name))).first() is not None:
                raise ValueError(f"a system named {name!r} already exists")
            seed_id = None
            if seed_host:
                seed_id = (await _addressed_agent_or_raise(session, seed_host)).id
            row = System(name=name, description=description or None, seed_agent_id=seed_id, edges=edges or [])
            for m in members or []:
                cfg = {k: v for k, v in m.items() if k not in _CORE and k != "id" and v is not None}
                row.members.append(SystemMember(target=str(m.get("target") or "native"),
                                                 app=str(m.get("app") or ""), role_in_system=m.get("role_in_system"),
                                                 config=cfg))
            session.add(row)
            await session.commit()
            await session.refresh(row)
            return {"id": str(row.id), "name": row.name, "member_count": len(row.members)}

    @mcp.tool()
    async def system_list() -> list[dict[str, Any]]:
        """List persisted Systems (id, name, member_count)."""
        from bossman.db.models import System
        async with session_factory() as session:
            rows = (await session.scalars(select(System).order_by(System.created_at.desc()))).all()
            return [{"id": str(s.id), "name": s.name, "member_count": len(s.members),
                     "seed_agent_id": str(s.seed_agent_id) if s.seed_agent_id else None} for s in rows]

    @mcp.tool()
    async def system_clone(system_name: str, target_host: str, dry_run: bool = True) -> dict[str, Any]:
        """Clone a System's seed host into a sandbox on target_host (docker names
        prefixed, host ports dropped). Dry-run by default — preview first."""
        from bossman.services import system_clone as _clone
        async with session_factory() as session:
            s = await _system_by_name_or_raise(session, system_name)
            target = await _addressed_agent_or_raise(session, target_host)
            return await _clone.clone_system(session, s, target, client_factory, settings, dry_run=dry_run)

    @mcp.tool()
    async def system_rehearse(system_name: str, target_host: str,
                              image_overrides: dict[str, str] | None = None, teardown: bool = True) -> dict[str, Any]:
        """Rehearse a change in a sandbox: bring the System's docker members up for
        real (with optional image_overrides = the change), health-gate, tear down.
        Returns pass/fail — the behavioral test before prod."""
        from bossman.services import system_rehearsal
        async with session_factory() as session:
            s = await _system_by_name_or_raise(session, system_name)
            target = await _addressed_agent_or_raise(session, target_host)
            return await system_rehearsal.rehearse(s, target, client_factory, settings,
                                                   image_overrides=image_overrides or {}, teardown=teardown)

    @mcp.tool()
    async def system_promote(system_name: str, target_host: str, image_overrides: dict[str, str],
                             rehearse_first: bool = True, dry_run: bool = False) -> dict[str, Any]:
        """Promote a change to prod as one atomic change-set, gated on a green
        rehearsal (rehearse_first). Preserves each container's spec; rolls the whole
        set back on any failure."""
        from bossman.services import system_promote
        async with session_factory() as session:
            s = await _system_by_name_or_raise(session, system_name)
            target = await _addressed_agent_or_raise(session, target_host)
            return await system_promote.promote(s, target, image_overrides, client_factory, settings,
                                                rehearse_first=rehearse_first, dry_run=dry_run)

    # --- Resource / Deployable verbs (docs/resource-protocol.md) --------------
    # One uniform lifecycle the AI drives across tiers: observe / plan / apply /
    # generations / rollback. kind = docker | helm (config/role fold in later).

    def _make_resource(session, agent, kind: str, name: str, namespace: str):
        if kind == "docker":
            from bossman.services.resources.docker_container import DockerContainerResource
            return DockerContainerResource(session, agent, client_factory, settings, name)
        if kind == "helm":
            from bossman.services.resources.helm_release import HelmReleaseResource
            return HelmReleaseResource(session, agent, client_factory, settings, name, namespace=namespace)
        if kind == "config":
            from bossman.services.resources.config_file import ConfigResource
            return ConfigResource(session, agent, client_factory, settings, name)  # name = file path
        if kind == "role":
            from bossman.services.resources.role import RoleResource
            return RoleResource(session, agent, client_factory, settings, name, requested_by="mcp")
        raise ValueError(f"unknown resource kind: {kind!r} (use docker|helm|config|role)")

    @mcp.tool()
    async def resource_observe(host: str, kind: str, name: str, namespace: str = "default") -> dict[str, Any]:
        """Observe a Resource's current state. kind=docker|helm|config|role."""
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            r = _make_resource(session, agent, kind, name, namespace)
            # config/role derive their schema behind I/O (per-directive fields /
            # the role's parameters); docker/helm answer synchronously.
            schema_async = getattr(r, "schema_async", None)
            schema = await schema_async() if schema_async else r.schema()
            return {"resource_key": r.resource_key, "observed": await r.observe(), "schema": schema}

    @mcp.tool()
    async def resource_plan(host: str, kind: str, name: str, desired: dict[str, Any],
                            namespace: str = "default") -> dict[str, Any]:
        """Diff a desired spec against the observed state (no write). desired for
        docker = {image,ports,env,volumes,restart}; for helm = {chart,values}."""
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await _make_resource(session, agent, kind, name, namespace).plan(desired)

    @mcp.tool()
    async def resource_apply(host: str, kind: str, name: str, desired: dict[str, Any],
                             dry_run: bool = True, note: str | None = None,
                             namespace: str = "default") -> dict[str, Any]:
        """Apply a desired spec (records a generation). dry_run=true returns the
        plan without writing — preview first for anything non-trivial."""
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await _make_resource(session, agent, kind, name, namespace).apply(
                desired, dry_run=dry_run, note=note)

    @mcp.tool()
    async def resource_generations(host: str, kind: str, name: str, namespace: str = "default") -> list[dict[str, Any]]:
        """The Resource's applied-generation history (rollback points)."""
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await _make_resource(session, agent, kind, name, namespace).generations()

    @mcp.tool()
    async def resource_rollback(host: str, kind: str, name: str, generation: int,
                                namespace: str = "default") -> dict[str, Any]:
        """Roll a Resource back to an earlier generation (re-applied as a NEW
        generation — forward-converge, uniform across tiers)."""
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            return await _make_resource(session, agent, kind, name, namespace).rollback(generation)

    @mcp.tool()
    async def list_plans() -> list[dict[str, Any]]:
        """List every available PLAN — a named, reusable procedure (install/
        configure a role, apply a config bundle) with its description and the
        params it accepts. Plans are the building blocks you execute with
        run_plan(plan, host). Use search_plans(query) to find one by intent;
        run_plan to execute (dry-run first)."""
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
    async def set_threshold(
        service_name: str,
        metric: str,
        warn: float | None = None,
        crit: float | None = None,
        comparison: str = "ge",
        host: str | None = None,
    ) -> dict[str, Any]:
        """Create a monitoring threshold rule (K5) — the AI authoring its own
        policy. Grades `metric` into the named service: WARN at `warn`, CRIT at
        `crit`, using `comparison` (ge|gt|le|lt|eq|ne — e.g. ge for "high is
        bad" like mem/disk %). Scope: one `host` (by name) if given, else a
        global default across the fleet. Host scope overrides global (CheckMK
        precedence). Takes effect on the next poll cycle."""
        if comparison not in ("gt", "lt", "ge", "le", "eq", "ne"):
            raise ValueError("comparison must be one of gt|lt|ge|le|eq|ne")
        scope_type = "host" if host else "global"
        async with session_factory() as session:
            scope_value = None
            if host is not None:
                agent = await session.scalar(select(Agent).where(Agent.name == host))
                if agent is None:
                    raise ValueError(f"no such host {host!r}")
                scope_value = host
            # Idempotent: update the existing rule for this service+metric+scope
            # rather than piling up duplicates (an AI may call this repeatedly).
            rule = await session.scalar(
                select(CheckRule).where(
                    CheckRule.service_name == service_name,
                    CheckRule.metric == metric,
                    CheckRule.scope_type == scope_type,
                    CheckRule.scope_value.is_(None) if scope_value is None else CheckRule.scope_value == scope_value,
                    CheckRule.is_default.is_(False),
                )
            )
            created = rule is None
            if rule is None:
                rule = CheckRule(service_name=service_name, metric=metric, scope_type=scope_type,
                                  scope_value=scope_value, enabled=True)
                session.add(rule)
            rule.comparison = comparison
            rule.warn_threshold = warn
            rule.crit_threshold = crit
            rule.enabled = True
            await session.commit()
            return {
                "rule_id": str(rule.id),
                "created": created,
                "service_name": service_name,
                "metric": metric,
                "comparison": comparison,
                "warn": warn,
                "crit": crit,
                "scope": f"host:{host}" if host else "global",
            }

    @mcp.tool()
    async def get_host_logs(
        host: str, lines: int = 100, level: str | None = None, since: str | None = None, unit: str | None = None
    ) -> dict[str, Any]:
        """Read a host's journald logs (read-only), for cross-signal debugging
        of a problem. `level` filters by severity (err|warning|…), `since` is a
        journalctl time spec ("-1h", "yesterday"), `unit` a systemd unit. Pair
        with diagnose_host / host_services to correlate a failing service with
        what the logs show."""
        params: dict[str, Any] = {"lines": max(1, min(lines, 5000))}
        if level:
            params["priority"] = level
        if since:
            params["since"] = since
        if unit:
            params["unit"] = unit
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
        try:
            return await client.call_tool("journal", params)
        except AgentClientError as exc:
            raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def get_host_processes(host: str, limit: int = 20) -> dict[str, Any]:
        """The host's live process table (top `limit` by CPU), for cross-signal
        debugging — each row is {pid, user, comm, command, cpu_percent (100 % =
        one core), rss_kib, ...}. On-demand pass-through; pair with diagnose_host
        to attribute a CPU/memory problem to the offending process."""
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
        try:
            return await client.processes(limit=max(1, min(limit, 200)))
        except AgentClientError as exc:
            raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def diagnose_host(host: str, log_lines: int = 40) -> dict[str, Any]:
        """Cross-signal snapshot for diagnosing a host's problems in ONE call:
        its non-OK services (each with the value + the warn/crit threshold it
        tripped), the most recent error-level journal lines, AND the top
        processes by CPU and by memory — the signals an AI needs to reason about
        *why* a host is unhealthy (e.g. attribute a CPU/mem alert to the
        offending process) and decide whether to correct config
        (call_agent_tool), tune a threshold (set_threshold), or act on a
        process. Read-only. Logs + processes are best-effort (empty if the host
        is unreachable)."""
        async with session_factory() as session:
            agent = await session.scalar(select(Agent).where(Agent.name == host))
            if agent is None:
                raise ValueError(f"no such host {host!r}")
            views = await query_agent_services(session, agent.id)
            reachable = bool(agent.address)
        problems = [_service_view_dict(v) for v in (views or []) if v.service.state != "OK"]
        all_services = len(views or [])
        recent_errors: list[Any] = []
        top_cpu: list[Any] = []
        top_mem: list[Any] = []
        log_error = None
        proc_error = None
        if reachable:
            async with session_factory() as session:
                agent = await _addressed_agent_or_raise(session, host)
                client = client_factory(agent, settings)
            try:
                res = await client.call_tool("journal", {"lines": max(1, min(log_lines, 500)), "priority": "err"})
                data = res.get("data") if isinstance(res, dict) else None
                recent_errors = (data or {}).get("entries") or (data or {}).get("lines") or (data if isinstance(data, list) else [])
            except AgentClientError as exc:
                log_error = str(exc)
            # Processes as a diagnosis source: the top few by CPU and by RSS, so
            # a high-cpu/high-mem service alert can be tied to a specific process.
            try:
                procs = (await client.processes(limit=0)).get("processes") or []
                def _slim(p: dict) -> dict:
                    return {k: p.get(k) for k in ("pid", "user", "comm", "command", "cpu_percent", "rss_kib")}
                top_cpu = [_slim(p) for p in sorted(procs, key=lambda p: p.get("cpu_percent") or 0, reverse=True)[:5]]
                top_mem = [_slim(p) for p in sorted(procs, key=lambda p: p.get("rss_kib") or 0, reverse=True)[:5]]
            except AgentClientError as exc:
                proc_error = str(exc)
        return {
            "host": host,
            "reachable": reachable,
            "services_total": all_services,
            "problem_count": len(problems),
            "problems": problems,
            "recent_errors": recent_errors,
            "top_processes_by_cpu": top_cpu,
            "top_processes_by_memory": top_mem,
            "log_error": log_error,
            "process_error": proc_error,
        }

    @mcp.tool()
    async def set_host_config(
        host: str,
        path: str,
        values: dict[str, Any],
        config_format: str = "keyvalue",
        separator: str = "",
        dry_run: bool = True,
    ) -> dict[str, Any]:
        """Correct a host's config (K4) — the write side of the document loop,
        diffable/versioned/rollback-able (NOT an ad-hoc edit). Converges `path`
        toward `values` using the file's codec (`config_format`: keyvalue|ini|
        …; `separator` for keyvalue). `values` is the desired key→value map (for
        ini, section→{key:value}). dry_run=true (default) returns the diff
        WITHOUT writing — always preview first, then re-call dry_run=false to
        apply. Needs the host's write gate open. Pair with diagnose_host: find
        the cause, preview the fix, apply it."""
        resource = {"type": "config", "path": path, "format": config_format,
                    "separator": separator, "values": values}
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
        try:
            return await client.state_apply({"resources": [resource]}, dry_run)
        except AgentClientError as exc:
            raise ValueError(str(exc)) from exc

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
        collection name (e.g. "posix.sysctl"): its documented options/argspec
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

    # ── Check library (Block G9) ─────────────────────────────────────────
    # Checks (Checkmk translations + custom) are READ-ONLY Starlark modules
    # stored FLAT in checks_dir, distinct from the Ansible modules above.
    # get_module_source serves their translation source too (fqcn
    # "checkmk.<name>"); submit_check writes them, list_checks_status is the
    # resumable queue.

    def _check_source_names() -> list[str]:
        from pathlib import Path

        return sorted(p.stem[len("checkmk.") :] for p in Path(settings.module_sources_dir).glob("checkmk.*.json"))

    @mcp.tool()
    async def list_checks(query: str = "") -> list[dict[str, Any]]:
        """FIND monitoring checks by what they DO. Returns the check catalog with
        each check's name, short_description, a one-paragraph summary, category and
        datasource (agent | snmp | ssh). Pass `query` to filter by substring over
        name/description/summary (e.g. "cpu", "disk", "postgres", "docker"). Use
        this to discover which check to assign to a host/scope; then get_check(name)
        for the full description + Starlark source. To assign one, author a threshold
        with set_threshold or assign via a policy."""
        rows = checks_library.list_checks(settings.checks_dir)
        q = query.strip().lower()
        if q:
            rows = [r for r in rows if q in (r.get("name", "") + " " + r.get("short_description", "") + " " + r.get("summary", "")).lower()]
        return rows

    @mcp.tool()
    async def get_check(name: str) -> dict[str, Any]:
        """READ one check in full: its metadata (short_description, the long
        markdown `description` explaining what it measures + its parameters/options)
        and the Starlark source. Use after list_checks to understand exactly what a
        check does and how to parametrize it before assigning it."""
        try:
            return checks_library.load_check(settings.checks_dir, name)
        except module_library.ModuleLibraryError as exc:
            raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def submit_check(name: str, metadata: str, star_code: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        """Store one translated/custom CHECK in the flat check library
        (<checks_dir>/<name>.{star,nt}). Like submit_module but for a
        read-only monitoring check: `metadata` is NestedText with writes:false
        and kind:check, and the Starlark main(ctx, params) must return
        {"changed": False, "msg": ..., "data": {"state": "OK|WARN|CRIT|UNKNOWN",
        "metrics": {...}, "details": ...}}. Validates first (same hard gate)
        and only persists on ok. `name` is the flat check name (e.g. "http")."""
        return checks_library.submit_check(
            settings.checks_dir, settings.starlark_check_path, name, metadata, star_code, params
        )

    @mcp.tool()
    async def list_checks_status() -> dict[str, Any]:
        """Translation progress of the CHECK library, derived from the
        filesystem: {total, translated, missing: [name, ...]}. The dumped
        checkmk.*.json sources define the universe; a stored <name>.star means
        translated. `missing` is the work queue — get_module_source
        ("checkmk.<name>"), translate to a read-only check module, then
        submit_check(name, ...). Safe to call any time for resume."""
        return checks_library.checks_status(settings.checks_dir, _check_source_names())

    @mcp.tool()
    async def run_runbook(
        runbook: str, host: str, variables: dict[str, Any] | None = None, apply: bool = False,
    ) -> dict[str, Any]:
        """Run a stored runbook against a host by name — e.g. an install-<pkg>
        wizard runbook to install AND configure a server role. `variables` fills
        the runbook's typed `parameters` (see list_runbooks/get_runbook for the
        input mask); anything you omit uses its default.

        By default this is a DRY-RUN (check_mode): every step is previewed,
        nothing on the host changes. A real apply (apply=true) mutates the host
        and is gated by the global YOLO-MAN switch — with it off, apply raises
        and you must have a human confirm via the UI/REST API (the
        AI-proposes-human-confirms posture). Returns the per-step result."""
        from bossman.db.models import Agent, Runbook
        from bossman.services import nt_runbook, runbook_exec

        async with session_factory() as session:
            rb = await session.scalar(select(Runbook).where(Runbook.name == runbook))
            if rb is None:
                raise ValueError(f"no such runbook {runbook!r}")
            agent = await session.scalar(select(Agent).where(Agent.name == host))
            if agent is None:
                raise ValueError(f"no such host {host!r}")
            if not agent.address:
                raise ValueError(f"host {host!r} has no reachable address")

            check_mode = not apply
            if apply and not await is_yolo_mode(session):
                raise ValueError(
                    "real apply is gated: the YOLO-MAN switch is off, so this tool can only "
                    "dry-run. Re-run with apply=false to preview, or have a human apply it "
                    "via the UI / REST API."
                )

            # parse_data reconstructs the canonical doc verbatim (handlers,
            # block/rescue/always, params) — straight from the canonical doc, no lossy round-trip.
            doc = nt_runbook.parse_data(rb.doc)
            if not isinstance(doc, nt_runbook.Runbook):
                raise ValueError(f"{runbook!r} is a role, not a runbook — bind it in OU/Policy")

            # Delegate to the ONE canonical run path the REST API uses, so the MCP
            # facade gets the same behaviour: magic facts + scope vars + typed
            # parameter defaults, config-template bodies, role-call expansion, and
            # the persisted RunbookRun — no drift, no missing pieces.
            client = client_factory(agent, settings)
            _run_row, rr = await runbook_exec.execute_runbook(
                session, agent, doc, settings=settings, client=client,
                request_vars=variables or {}, dry_run=check_mode,
                requested_by=(current_identity.get() or "mcp-facade"), commit=True,
            )
        return {"runbook": doc.name, "host": host, "dry_run": check_mode, **rr}

    @mcp.tool()
    async def list_runbooks(folder: str | None = None) -> list[dict[str, Any]]:
        """List stored runbooks (optionally filtered by folder, e.g. "wizards"
        for the package-installation runbooks). Each entry carries its typed
        `parameters` (the input mask: name -> {type, description, default, ...}),
        so you know what to pass to run_runbook. The install-<pkg> runbooks
        install and configure a server package in one procedure."""
        from bossman.db.models import Runbook

        async with session_factory() as session:
            q = select(Runbook).where(Runbook.tenant_id == DEFAULT_TENANT_ID)
            if folder is not None:
                q = q.where(Runbook.folder == folder)
            rows = (await session.scalars(q.order_by(Runbook.name))).all()
            return [{"name": r.name, "kind": r.kind, "folder": r.folder or "",
                     "steps": len((r.doc or {}).get("steps", [])),
                     "parameters": (r.doc or {}).get("parameters", {})} for r in rows]

    @mcp.tool()
    async def search_runbooks(query: str, top_k: int = 8) -> list[dict[str, Any]]:
        """Find runbooks by name/folder substring (case-insensitive). Returns the
        same shape as list_runbooks (incl. `parameters`)."""
        from bossman.db.models import Runbook

        ql = query.lower()
        async with session_factory() as session:
            rows = (await session.scalars(
                select(Runbook).where(Runbook.tenant_id == DEFAULT_TENANT_ID).order_by(Runbook.name)
            )).all()
            hits = [r for r in rows if ql in r.name.lower() or ql in (r.folder or "").lower()]
            return [{"name": r.name, "kind": r.kind, "folder": r.folder or "",
                     "parameters": (r.doc or {}).get("parameters", {})} for r in hits[:top_k]]

    @mcp.tool()
    async def get_runbook(runbook: str) -> dict[str, Any]:
        """Read one runbook in full: its Ansible-task `playbook` YAML (the
        authoring/interchange surface), typed `parameters` input mask, and steps.
        Pair with run_runbook."""
        from bossman.db.models import Runbook
        from bossman.services import ansible_playbook, nt_convert

        async with session_factory() as session:
            rb = await session.scalar(
                select(Runbook).where(Runbook.tenant_id == DEFAULT_TENANT_ID, Runbook.name == runbook)
            )
            if rb is None:
                raise ValueError(f"no such runbook {runbook!r}")
            out = {
                "name": rb.name, "kind": rb.kind, "folder": rb.folder or "",
                "parameters": (rb.doc or {}).get("parameters", {}),
                "steps": (rb.doc or {}).get("steps", []),
            }
            # The Ansible-task YAML surface (only meaningful for runbooks, not roles).
            if rb.kind == "runbook":
                try:
                    out["playbook"] = ansible_playbook.doc_to_playbook(rb.doc)
                except Exception:  # noqa: BLE001 — never fail a read over the extra surface
                    pass
            return out

    # ── Config roles & templates (installation-wizard lifecycle) ─────────
    # The catalog + templates that drive Roles & Features / the install wizard.
    # Together with run_runbook(install-<pkg>) this lets you discover a role,
    # read its config template + parameter schema, install and configure it,
    # then verify — the whole role lifecycle over MCP.

    def _catalog_dict() -> dict[str, Any]:
        path = Path(settings.config_templates_dir).parent / "package_catalog.json"
        try:
            return json.loads(path.read_text())
        except (OSError, ValueError):
            return {}

    @mcp.tool()
    async def list_roles(installable_only: bool = True) -> list[dict[str, Any]]:
        """List server roles from the package catalog (the Roles & Features
        surface): name, label, category, config template, and the package names
        per OS family. installable_only=true hides base-system config files
        (kind=config) and returns only real roles (kind=role). Install one with
        run_runbook("install-<name>", host, variables=…)."""
        cat = _catalog_dict()
        out = []
        for name, e in sorted(cat.items()):
            if installable_only and e.get("kind") == "config":
                continue
            out.append({"name": name, "label": e.get("label", name), "category": e.get("category", ""),
                        "kind": e.get("kind", ""), "template": e.get("template"),
                        "families": e.get("families", {})})
        return out

    @mcp.tool()
    async def get_role(name: str) -> dict[str, Any]:
        """Full catalog entry for one role + its config template (Jinja2) and
        values schema (the wizard's parameter mask). Everything needed to render
        or reason about the role's config."""
        cat = _catalog_dict()
        entry = cat.get(name)
        if entry is None:
            raise ValueError(f"no such role {name!r}")
        result = dict(entry)
        tname = entry.get("template")
        if tname:
            tdir = Path(settings.config_templates_dir) / tname
            for fname, key in (("template.j2", "template"), ("schema.json", "schema"), ("sample.json", "sample")):
                fp = tdir / fname
                if fp.is_file():
                    try:
                        result[key] = json.loads(fp.read_text()) if fname.endswith(".json") else fp.read_text()
                    except (OSError, ValueError):
                        pass
        return result

    @mcp.tool()
    async def list_config_templates(query: str = "") -> list[dict[str, Any]]:
        """FIND config templates by what they configure. Each template (a Jinja2
        body + a values schema, per config file) becomes an entry with its name,
        the number of settings, and a short description synthesized from the
        schema's field descriptions — so you can pick the right one without opening
        each. Pass `query` to filter by substring over name/description (e.g.
        "nginx", "ntp", "ssh"). Then get_config_template(name) for the full schema
        (every setting: type, default, allowed values, description) + the Jinja2."""
        tdir = Path(settings.config_templates_dir)
        if not tdir.is_dir():
            return []
        out: list[dict[str, Any]] = []
        for d in sorted(p for p in tdir.iterdir() if p.is_dir() and (p / "template.j2").is_file()):
            fields = 0
            descs: list[str] = []
            try:
                schema = json.loads((d / "schema.json").read_text())
                if isinstance(schema, dict):
                    for spec in schema.values():
                        if isinstance(spec, dict) and "type" in spec:
                            fields += 1
                            de = spec.get("description")
                            if de and len(descs) < 4:
                                descs.append(str(de))
            except (OSError, ValueError):
                pass
            desc = "; ".join(descs) or f"Config template for {d.name}"
            out.append({"name": d.name, "settings": fields, "description": desc[:300]})
        q = query.strip().lower()
        if q:
            out = [t for t in out if q in (t["name"] + " " + t["description"]).lower()]
        return out

    @mcp.tool()
    async def qualify_package(name: str) -> dict[str, Any]:
        """Create ALL config artifacts for a package — codec classification,
        per-directive value catalog, the Jinja2 template + values schema, and enum
        enrichment — then categorize it into the package catalog (einsortiert).

        Runs the SAME qualify pipeline the host batch uses (scripts/qualify_packages.py
        + build_package_catalog.py), against the RW-mounted configs and Bossman's
        CONFIGURED AI endpoint. Use this to onboard a new package/service so it shows
        up in the wizard, Roles & Features and the gpedit config editor. Returns
        whether the template was created, the assigned category, the codec, and a
        log tail. Takes a couple of minutes."""
        from bossman.api.package_qualify import run_qualify

        res = await run_qualify(name)
        return res.model_dump()

    @mcp.tool()
    async def get_config_template(name: str) -> dict[str, Any]:
        """Read a config template: its Jinja2 body, values schema (each var ->
        type/default/description; list-of-object vars carry an `items` shape),
        and sample values. This is the source of a role's parameter mask."""
        tdir = Path(settings.config_templates_dir) / name
        if not tdir.is_dir():
            raise ValueError(f"no such config template {name!r}")
        out: dict[str, Any] = {"name": name}
        for fname, key, is_json in (("template.j2", "template", False),
                                    ("schema.json", "schema", True),
                                    ("sample.json", "sample", True)):
            fp = tdir / fname
            if fp.is_file():
                try:
                    out[key] = json.loads(fp.read_text()) if is_json else fp.read_text()
                except (OSError, ValueError):
                    pass
        return out

    @mcp.tool()
    async def get_doc_audit(role: str | None = None) -> dict[str, Any]:
        """Read the package-doc completeness audit (qwen vs. official docs via
        SearXNG). Without `role`, returns a summary of which roles are complete
        vs. incomplete; with `role`, the detailed findings (missing directives,
        missing lifecycle steps, sources). Use it to know what a template/runbook
        still lacks before refining it."""
        path = Path(settings.config_templates_dir).parent / "package_doc_audit.json"
        try:
            audit = json.loads(path.read_text())
        except (OSError, ValueError):
            return {"audited": 0, "note": "no audit has run yet"}
        if role is not None:
            entry = audit.get(role)
            if entry is None:
                raise ValueError(f"role {role!r} has not been audited")
            return entry
        return {
            "audited": len(audit),
            "incomplete": sorted(k for k, v in audit.items() if v.get("verdict") == "incomplete"),
            "complete": sorted(k for k, v in audit.items() if v.get("verdict") == "complete"),
        }

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
