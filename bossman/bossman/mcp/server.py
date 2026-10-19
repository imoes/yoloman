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
from bossman.services.plan_loader import PlanError
from bossman.services.scope_vars import resolve_scope_vars
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
    async def whatif_scope(
        scope_type: str, ou: str = "", group: str = "", site: str = "", host: str = "",
        conditions: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Blast radius BEFORE you create a policy: which hosts a policy at this
        scope + these Checkmk conditions would apply to. scope_type is
        ou|group|site|host|global; pass the matching name in ou/group/site/host.
        conditions is the same shape as a policy's conditions (host_tags,
        host_facts, host_vars, host_label_groups, host_name, host_folder,
        service_*). Returns {total_in_scope, matched_count, matched, excluded}.
        Use this to check a proposed policy hits what you expect before applying."""
        from bossman.db.models import HostGroup, OUNode, Site
        from bossman.services.whatif import whatif_scope as _whatif

        async with session_factory() as session:
            ou_id = group_id = site_id = agent_id = None
            if scope_type == "ou" and ou:
                row = await session.scalar(select(OUNode).where(OUNode.path == ou))
                ou_id = row.id if row else None
            elif scope_type == "group" and group:
                row = await session.scalar(select(HostGroup).where(HostGroup.name == group))
                group_id = row.id if row else None
            elif scope_type == "site" and site:
                row = await session.scalar(select(Site).where(Site.name == site))
                site_id = row.id if row else None
            elif scope_type == "host" and host:
                row = await session.scalar(select(Agent).where(Agent.name == host))
                agent_id = row.id if row else None
            return await _whatif(
                session, scope_type, ou_id=ou_id, host_group_id=group_id,
                site_id=site_id, agent_id=agent_id, conditions=conditions or {},
            )

    @mcp.tool()
    async def desired_state_diff(host: str, from_gen: int = 0, to_gen: int = 0) -> dict[str, Any]:
        """Time machine: what changed in a host's desired_state between two
        generations (leaf-level added/removed/changed). Defaults (0/0) diff the
        previous generation → the current one. Use desired_state generations via
        get_server_document / the REST history to pick specific generations.
        Answers "what changed on this host, and when"."""
        async with session_factory() as session:
            agent = await session.scalar(select(Agent).where(Agent.name == host))
            if agent is None:
                raise ValueError(f"no such host {host!r}")
            from bossman.services.state_history import diff_generations

            return await diff_generations(
                session, agent.id, from_gen or None, to_gen or None
            )

    @mcp.tool()
    async def operation_log(host: str = "", module: str = "", outcome: str = "", since_minutes: int = 0,
                            changed_only: bool = False, limit: int = 100) -> dict[str, Any]:
        """WHAT THE FLEET ACTUALLY DID, and what came back — the record, not a summary of it.

        Answers the questions a reply to whoever was waiting cannot: did that install work, what did the
        host say when it refused, which hosts changed in the last hour, what was the plan before it ran.
        Every collected module call carries the EVIDENCE verbatim (exit code, the -WhatIf plan, the
        detection rule before/after, the target's own error text), so an analysis reads the same thing an
        operator does.

        OUTCOMES, exhaustive and each meaning something different — read them before concluding anything:
        `changed` (the host is different now), `unchanged` (it was already as asked — the idempotence
        claim), `planned` (a DRY RUN: a preview, nothing was done), `refused` (the TARGET said no; its
        words are in `error`), `error` (the agent broke — a fact about us, not the host), `timed-out` (the
        caller stopped waiting — THE OPERATION MAY HAVE COMPLETED, so never report it as a failure without
        re-reading the state), `unknown-module`, and `gap` (records fell out of an agent's ring buffer
        before collection: that range is gone, and this row says so rather than leaving a hole that reads
        like quiet).

        Filters are ANDed; every argument is optional (empty string / 0 = no filter). Read-only.
        """
        from bossman.api.management import OPERATION_OUTCOMES, list_operations

        if outcome and outcome not in OPERATION_OUTCOMES:
            raise ValueError(f"unknown outcome {outcome!r}; it is one of {', '.join(OPERATION_OUTCOMES)}")
        since = (datetime.now(timezone.utc) - timedelta(minutes=since_minutes)) if since_minutes else None
        async with session_factory() as session:
            return await list_operations(
                host=host or None, agent_id=None, module=module or None, outcome=outcome or None,
                since=since, changed_only=changed_only, limit=max(1, min(limit, 2000)),
                session=session, _identity=None,
            )

    @mcp.tool()
    async def propose_config_policy(instruction: str) -> dict[str, Any]:
        """Turn a plain-language request ("set the NTP server to 10.0.0.1 on all
        Debian web servers in Munich") into a STRUCTURED, reviewable config-policy
        proposal — path, format, values, scope and Checkmk conditions — grounded
        in the fleet's real OUs/groups/sites and tag/fact/variable keys, plus the
        blast radius (which hosts it would hit). Never applies anything: review
        the proposal, then create it (dry_run first) to apply. Returns {applied:
        false, proposal, blast_radius, note}."""
        from bossman.services.nl_policy import propose_policy_from_nl

        async with session_factory() as session:
            return await propose_policy_from_nl(session, settings, instruction)

    @mcp.tool()
    async def extract_docker_vars(image: str) -> dict[str, Any]:
        """Extract a Docker image's configurable variables from its Docker Hub
        README (env vars → params, plus ports/volumes) via the configured
        OpenRouter model, and store it in the app-store docker catalog. Returns
        {image, name, description, variables, ports, volumes}. e.g. image="postgres"."""
        from bossman.services.docker_readme import extract_and_store

        async with session_factory() as session:
            row = await extract_and_store(session, settings, image.strip())
            await session.commit()
            return {
                "image": row.image, "name": row.name, "description": row.description,
                "variables": row.variables or [], "ports": row.ports or [], "volumes": row.volumes or [],
            }

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
        provides it — the deterministic Lego matcher (same logic as the REST /capabilities/match).
        Returns, per open requirement: the capability + accepted backends, the matching
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

    async def _authorize_host(session: AsyncSession, agent: Agent) -> None:
        """The host ACL, exactly as REST's require_manage_agent applies it: admin users bypass, every api
        token needs a grant (all, host, or a host_group the host is in). Applied to every tool that
        contacts a host's agent or runs something against it — before this, MCP checked no ACL at all, so a
        token REST refuses with 403 could run `command` and `reboot` through call_agent_tool. Reading
        Bossman's own records (host_status, list_problems, recent_diagnoses, ...) stays open, as it is over
        REST. Fails closed: a call that did not pass the bearer middleware has no identity and is refused."""
        from bossman.mcp.auth import current_auth_identity
        from bossman.services.auth import user_can_manage_agent

        identity = current_auth_identity.get()
        if identity is None or not await user_can_manage_agent(session, identity, agent.id):
            raise ValueError(f"not authorized to manage {agent.name!r}: the API token needs a host, host_group or "
                             "all grant (POST /api/v1/access-grants)")

    async def _addressed_agent_or_raise(session: AsyncSession, host: str) -> Agent:
        agent = await session.scalar(select(Agent).where(Agent.name == host))
        if agent is None:
            raise ValueError(f"no such host {host!r}")
        if not agent.address:
            raise ValueError(f"host {host!r} has no reachable address (satellite/unenrolled)")
        await _authorize_host(session, agent)
        return agent

    @mcp.tool()
    async def list_agent_tools(host: str) -> list[dict[str, Any]]:
        """Router: list the tools one managed agent currently exposes
        ([{name, kind, writes, supported, unsupported_reason}]), by host name.
        Bossman is a gateway — use list_hosts to see the fleet of managed
        servers, this to discover a given server's tools, then call_agent_tool
        to invoke one.

        CHECK `supported`. An entry with supported=false is a NAMED refusal, not
        a callable tool: `unsupported_reason` says why this host cannot do it,
        and often which module does the job here instead (a Windows agent lists
        apt as unsupported and points at winget). It is listed rather than
        omitted because a missing entry cannot be told apart from an agent too
        old to have the module — so do not call it, and do not read its absence
        of a schema as "no parameters". On the Go agent every listed tool is
        supported and the field may be absent.

        Write tools appear only when that agent's write gate is open."""
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
        try:
            return await client.list_tools()
        except AgentClientError as exc:
            raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def call_agent_tool(
        host: str, tool: str, params: dict[str, Any] | None = None, dry_run: bool = False,
        timeout_seconds: int | None = None,
    ) -> dict[str, Any]:
        """Router: invoke one tool on a managed agent by host name, proxied
        through Bossman to the agent's own tool endpoint. `params` are the
        tool's parameters; `dry_run=true` is forwarded so write modules run in
        check_mode. The agent's write gate + ACL + audit are the enforcement
        point — a read-only agent rejecting a write tool raises the agent's
        error. Discover tools first with list_agent_tools.

        timeout_seconds (1–7200): how long to wait for the agent's answer. Default: 30 s, or 900 s for the
        tools known to run long (package installs, benchmarks, update-grub, scx builds). A timeout does not mean
        the tool failed — re-read the state before retrying."""
        if timeout_seconds is not None and not 1 <= int(timeout_seconds) <= 7200:
            raise ValueError("timeout_seconds must be between 1 and 7200")
        body = dict(params or {})
        if dry_run:
            body["dry_run"] = True
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
        try:
            extra = {"timeout": float(timeout_seconds)} if timeout_seconds else {}
            return await client.call_tool(tool, body, **extra)
        except AgentClientError as exc:
            raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def update_agent(host: str, dry_run: bool = True) -> dict[str, Any]:
        """Update one host's agent to the package Bossman ships (.deb for Debian/Ubuntu, .rpm for
        RHEL/Fedora/SUSE, chosen by the host's OS family). dry_run=true (default) says which package would
        be pushed (path, size, sha256) and the version the host reports now; dry_run=false pushes it, the
        agent installs it and restarts (it is back within a few seconds — check with
        call_agent_tool(host, "setup")). Needs the same host grant as the REST route
        (POST /api/v1/agents/{id}/update-bundled); a host whose OS family is unknown is refused rather
        than being sent the wrong package."""
        from bossman.services.agent_update import AgentUpdateRefused, bundled_package, push_bundled

        async with session_factory() as session:
            agent = await session.scalar(select(Agent).where(Agent.name == host))
            if agent is None:
                raise ValueError(f"no such host {host!r}")
            await _authorize_host(session, agent)
            try:
                if dry_run:
                    pkg = bundled_package(agent, settings)
                    return {"dry_run": True, "host": host, "current_version": agent.agent_version, **pkg.as_dict()}
                return {"dry_run": False, "host": host, "previous_version": agent.agent_version,
                        **await push_bundled(agent, settings, client_factory)}
            except AgentUpdateRefused as exc:
                raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def vm_hosts(placement: bool = False) -> dict[str, Any]:
        """The hypervisors Bossman can create VMs on (Proxmox/vCenter), the golden images it can restore onto them,
        and the network installs (fedora, alma, debian, ubuntu — default packages, minimum memory). placement=true also asks each hypervisor for its nodes and, per node, the storages that can
        hold a disk and the bridges a NIC can attach to — what deploy_vm needs."""
        from bossman.db.models import DiskImage, VmHost
        from bossman.services import hypervisor as _hv
        from bossman.services import vm_provision as vp

        async with session_factory() as session:
            from bossman.services import netinstall as _ni

            images = [{"name": i.name, "status": i.status, "description": i.description}
                      for i in (await session.scalars(select(DiskImage).order_by(DiskImage.name))).all()]
            installs = _ni.catalog()
            out = []
            for h in (await session.scalars(select(VmHost).order_by(VmHost.name))).all():
                row: dict[str, Any] = {"name": h.name, "kind": h.kind, "host": h.host}
                if placement:
                    try:
                        row["placement"] = await vp.client_for(h).placement()
                    except _hv.HypervisorError as exc:
                        row["placement_error"] = str(exc)[:300]
                out.append(row)
            return {"images": images, "installs": installs, "vm_hosts": out}

    @mcp.tool()
    async def check_ip(addresses: list[str], prefix_len: int = 24) -> list[dict[str, Any]]:
        """Is an IPv4 address free? Asks three sources and names each answer: Bossman's own records (agents,
        their inventory, planned hosts' static addresses), NetBox when configured, and a live ping + ARP from an
        enrolled agent in the same subnet. verdict = in_use | free | unknown — free only when the live probe ran
        and saw nothing and no record holds it (NetBox alone is not trusted: it listed live addresses as free)."""
        from bossman.services import ip_check

        async with session_factory() as session:
            return await ip_check.check(session, settings, client_factory, addresses, prefix_len)

    @mcp.tool()
    async def suggest_free_ips(prefix: str, count: int = 5) -> dict[str, Any]:
        """Up to `count` addresses in `prefix` (e.g. 192.0.2.0/24) that every source agrees are free — the
        candidates come from NetBox's available-ips when configured, each is verified with check_ip; the
        rejected ones are listed with the reason."""
        from bossman.services import ip_check

        async with session_factory() as session:
            return await ip_check.suggest(session, settings, client_factory, prefix, count)

    @mcp.tool()
    async def deploy_vm(name: str, address: str, gateway: str, dns: list[str], vm_host: str = "", node: str = "",
                        storage: str = "", bridge: str = "", image: str | None = None, install: str | None = None,
                        vlan: int | None = None, hostname: str | None = None, cores: int = 2, memory_mb: int = 2048,
                        disk_gib: int = 32, uefi: bool = False, roles: list[Any] | None = None,
                        packages: list[str] | None = None, write: bool = True, finalize_runbook: str | None = None,
                        finalize_variables: dict[str, Any] | None = None, finalize_apply: bool = False,
                        target: str = "vm", mac: str = "", grow_policy: dict[str, int] | None = None,
                        grow_mode: str = "percent", production_vlan: int | None = None,
                        production_bridge: str | None = None, dry_run: bool = True) -> dict[str, Any]:
        """Deploy a host with a static `address` (CIDR, e.g. 192.0.2.134/24), its agent enrolled.
        target="vm" (default) creates the VM on a registered hypervisor (vm_host, node, storage, bridge, vlan —
        see vm_hosts); target="bare_metal" takes an existing machine by its `mac` (required for install; for an
        image an empty mac arms a job the next PXE-booting machine claims). Give exactly one of:
        * image=<golden image> — PXE-restore of a captured image (Debian family); grow_policy + grow_mode size its
          growable volumes for THIS deployment (keys: mountpoint like "/var" or role like "root"; percent: each
          but the last takes its share, the last takes the rest; absolute: GiB, one 0 fills the rest);
          production_vlan (Proxmox tag on the same bridge) / production_bridge (vCenter portgroup) move the VM's
          NIC there after imaging;
        * install="<distro>[-<release>]" — the distribution's own network installer, newest stable/LTS when no
          release is given: fedora, alma (AlmaLinux), debian (stable), ubuntu (newest LTS; needs memory_mb >= 8192).
          `packages` replaces the distribution's default set (vm_hosts lists it); every package is checked against
          the distribution's repositories before the VM exists.
        roles (names, or {"name", "params"}) are bound to the new host as desired state and converge after its
        first report — approval-gated unless YOLO mode is on. finalize_runbook (a stored runbook, see list_runbooks)
        runs once the new host's agent first reports, with
        finalize_variables; finalize_apply=false runs it in check mode — applying needs YOLO mode for an AI caller,
        the same gate as run_runbook. The VM's MAC comes from the hypervisor and the PXE DHCP answers ONLY that
        MAC. dry_run=true (default) runs every pre-flight check and creates nothing; dry_run=false refuses while a
        check fails, then creates the VM and arms the restore or install; follow it with deployment_status."""
        from bossman.services import vm_provision as vp

        req = {"vm_host": vm_host, "node": node, "name": name, "storage": storage, "bridge": bridge, "address": address,
               "gateway": gateway, "dns": dns, "image": image, "install": install, "vlan": vlan, "hostname": hostname,
               "cores": cores, "memory_mb": memory_mb, "disk_gib": disk_gib, "uefi": uefi, "roles": roles,
               "packages": packages, "write": write, "finalize_runbook": finalize_runbook,
               "finalize_variables": finalize_variables, "finalize_apply": finalize_apply, "target": target,
               "mac": mac, "grow_policy": grow_policy, "grow_mode": grow_mode, "production_vlan": production_vlan,
               "production_bridge": production_bridge, "dry_run": dry_run}
        async with session_factory() as session:
            try:
                return await vp.deploy(session, settings, client_factory, req=req,
                                       requested_by="ai:" + (current_identity.get() or "mcp"), ai=True)
            except vp.ProvisionError as exc:
                raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def experiment_start(host: str, tunable: str, params: dict[str, Any], profile: str, runs: int = 5,
                               hypothesis: str = "", snapshot: bool = False) -> dict[str, Any]:
        """MEASURE whether a kernel tunable helps, instead of guessing (docs/kernel-tuning.md, block 5).
        tunable is a tunable resource name (sched_ext, systemd_resource:<unit>, blockdev_tuning:<device>,
        cpu_governor, kernel_cmdline); params are the candidate's module parameters (what resource_apply's
        desired.params would be); profile a yoloman.benchmark profile (sched_latency, sched_throughput, cpu, memory,
        io_randread); runs per side (3–20, default 5). Runs alternate A (the host as it is) and B (the candidate);
        the candidate is undone after each B run and the host ends at A. snapshot=true (block 6, a VM Bossman
        deployed): a hypervisor snapshot is taken first and the VM rolled back to it at the end — required for a
        tunable that needs a reboot. Refused before anything changes when the host refuses the candidate or it is
        what the host already has. Returns the experiment id; follow it with experiment_status(id, wait_s=300).
        The verdict is better | worse | no_difference | inconclusive | aborted, with every number it rests on —
        report it as it is; a change inside the noise band is no_difference, never better."""
        from bossman.services import experiment as ex

        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            try:
                return await ex.start(session, agent=agent, tunable=tunable, params=params, profile=profile, runs=runs,
                                      hypothesis=hypothesis, requested_by="ai:" + (current_identity.get() or "mcp"),
                                      session_factory=session_factory, settings=settings, client_factory=client_factory,
                                      snapshot=snapshot)
            except ex.ExperimentError as exc:
                raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def experiment_status(experiment_id: str, wait_s: int = 0) -> dict[str, Any]:
        """One experiment: status (running | done | aborted), verdict, summary (medians, IQR, noise band, delta,
        reason, whether the host is back at A), every measurement, the undo used. wait_s (0–900) waits until it
        finishes or records a new run instead of polling in a loop."""
        from bossman.services import experiment as ex

        async with session_factory() as session:
            try:
                return await ex.status(session, experiment_id, wait_s=wait_s)
            except ex.ExperimentError as exc:
                raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def experiments(host: str = "", limit: int = 20) -> list[dict[str, Any]]:
        """Recent tuning experiments, newest first — of one host, or of all hosts when host is empty."""
        from bossman.services import experiment as ex

        async with session_factory() as session:
            agent = None
            if host:
                agent = await session.scalar(select(Agent).where(Agent.name == host))
                if agent is None:
                    raise ValueError(f"no such host {host!r}")
            return await ex.list_for(session, agent, limit=max(1, min(int(limit), 200)))

    @mcp.tool()
    async def set_netboot(enabled: bool) -> dict[str, Any]:
        """Switch PXE netboot on or off (the WebUI's netboot toggle, same implementation). While on, the PXE
        DHCP answers ONLY the MACs of armed restore/install jobs (a job without a MAC opens it to everyone for a
        bounded window) — see deploy_vm. Fleet-wide, so it needs an all-hosts grant, not a host grant. When no
        secret exists yet a random one is generated (the operator can rotate it in the WebUI)."""
        import secrets as _secrets

        from bossman.api.system_settings import _get_or_seed, apply_netboot
        from bossman.services import netboot_dhcp

        async with session_factory() as session:
            await _require_fleet_grant(session, "set_netboot")
            row = await _get_or_seed(session)
            secret = None if (row.netboot_secret or settings.netboot_secret or not enabled) else _secrets.token_urlsafe(24)
            try:
                row = await apply_netboot(session, enabled=enabled, secret=secret,
                                          who="ai:" + (current_identity.get() or "mcp"))
            except ValueError as exc:
                raise ValueError(str(exc)) from exc
            pol = await netboot_dhcp.policy(session, enabled=enabled, open_minutes=settings.netboot_open_dhcp_minutes)
            return {"netboot_enabled": row.netboot_enabled, "secret_generated": secret is not None,
                    "updated_by": row.updated_by, **pol}

    async def _require_fleet_grant(session: AsyncSession, what: str) -> None:
        from bossman.mcp.auth import current_auth_identity
        from bossman.services.auth import grants_of

        identity = current_auth_identity.get()
        ok = identity is not None and ((identity.kind == "user" and identity.role == "admin")
                                       or any(g.scope == "all" for g in await grants_of(session, identity)))
        if not ok:
            raise ValueError(f"{what} is fleet-wide: the API token needs an 'all' grant (POST /api/v1/access-grants)")

    @mcp.tool()
    async def vm_status(vm_host: str, vmid: str = "", name: str = "", node: str | None = None) -> dict[str, Any]:
        """A VM's power state and how it boots: status (running|stopped), qmpstatus, uptime, and its config's
        name, net0 (MAC, bridge, VLAN tag), boot order, bios, memory, cores, disk. By vmid or by the VM's name;
        node is looked up when omitted."""
        from bossman.services import hypervisor as _hv
        from bossman.services import vm_provision as vp

        async with session_factory() as session:
            try:
                host = await vp.vm_host_by_name(session, vm_host)
            except vp.ProvisionError as exc:
                raise ValueError(str(exc)) from exc
        try:
            return await vp.client_for(host).vm_status(vmid, node, name)
        except (_hv.HypervisorError, AttributeError) as exc:
            raise ValueError(f"vm_status on {vm_host}: {exc}") from exc

    @mcp.tool()
    async def vm_power(vm_host: str, vmid: str, action: str, node: str | None = None) -> dict[str, Any]:
        """start | stop | reset | shutdown a VM on a registered hypervisor. Needs an all-hosts grant (it can take
        any VM on that hypervisor down)."""
        from bossman.services import hypervisor as _hv
        from bossman.services import vm_provision as vp

        async with session_factory() as session:
            await _require_fleet_grant(session, "vm_power")
            try:
                host = await vp.vm_host_by_name(session, vm_host)
            except vp.ProvisionError as exc:
                raise ValueError(str(exc)) from exc
        try:
            return await vp.client_for(host).vm_power(vmid, action, node)
        except (_hv.HypervisorError, AttributeError) as exc:
            raise ValueError(f"vm_power on {vm_host}: {exc}") from exc

    @mcp.tool()
    async def vm_delete(vm_host: str, vmid: str, remove_host: bool = False) -> dict[str, Any]:
        """Destroy a VM and its disks — ONLY a VM Bossman created through deploy_vm (an install or restore job
        names its vmid); anything else is refused. Its deployment becomes vm_deleted. Its host (agent row) is
        removed when it never reported; remove_host=true removes it also when it did, with its history — the VM
        is gone, so is the host. Needs an all-hosts grant."""
        from bossman.services import vm_provision as vp

        async with session_factory() as session:
            await _require_fleet_grant(session, "vm_delete")
            try:
                host = await vp.vm_host_by_name(session, vm_host)
                return await vp.delete_vm(session, host, vmid, remove_host=remove_host)
            except vp.ProvisionError as exc:
                raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def deployment_status(hostname: str, wait_s: int = 0) -> dict[str, Any]:
        """Where a deploy_vm stands: `install` (network install: pending → installing → done | failed | vm_deleted)
        or `restore` (golden image: status, step n/m, error, log tail), `host` (enrolment, address, agent version,
        last report) and `finalize` (playbook: waiting → running → done | failed | cancelled).

        wait_s (0–600): wait up to that many seconds for something to change (a status, the step, the first
        report, the finalization) before answering, instead of polling in a loop. The answer says `waited_s` and
        `changed`. An install takes 4–15 minutes, so wait_s=300 per call is a good rhythm."""
        import asyncio
        import time

        from bossman.services import finalize as fin
        from bossman.services import vm_provision as vp

        def mark(st: dict[str, Any]) -> tuple:
            i, r, h, f = (st.get(k) or {} for k in ("install", "restore", "host", "finalize"))
            return (i.get("status"), r.get("status"), r.get("step"), h.get("last_seen_at") is not None, f.get("status"))

        async def once() -> dict[str, Any]:
            async with session_factory() as session:
                await fin.kick(session, session_factory=session_factory, settings=settings, client_factory=client_factory)
                try:
                    return await vp.status(session, hostname)
                except vp.ProvisionError as exc:
                    raise ValueError(str(exc)) from exc

        wait_s = max(0, min(int(wait_s or 0), 600))
        t0 = time.monotonic()
        st = await once()
        first = mark(st)
        while wait_s and time.monotonic() - t0 < wait_s:
            await asyncio.sleep(min(10.0, wait_s - (time.monotonic() - t0)))
            st = await once()
            if mark(st) != first:
                break
        if wait_s:
            st = {**st, "waited_s": round(time.monotonic() - t0), "changed": mark(st) != first}
        return st

    @mcp.tool()
    async def diagnose_service(host: str, name: str) -> dict[str, Any]:
        """WHY DOES A SERVICE NOT RUN? Asks the host's own diagnosis (`service_diagnose`, Windows service or
        systemd unit) and returns the stored document: `summary`, `findings` (rule_id, claim, certainty,
        evidence_ids, precedent, remedy, gap), `evidence` (each measurement with its id, source, fact, raw),
        `timeline`, `gaps`, plus `contract_status` (ok | violation, with reasons).

        HOW TO USE IT HONESTLY: the certainty is the agent's, measured — Proven (read directly), Likely (inferred),
        Unknown (with the gap that names what could not be measured). Repeat it, never raise it. Cite evidence ids
        for every statement. A `precedent` is the most recent change before the failure — a correlation, not a
        cause. A `remedy` is data (before/after/rollback/verify): propose it, do not apply it on your own.
        contract_status "violation" means the document does not hold — say so and why. Read-only on the host."""
        from bossman.services import diagnosis as diag
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
            try:
                row = await diag.diagnose(session, agent, client, name)
            except diag.DiagnosisUnavailable as exc:
                raise ValueError(str(exc)) from exc
            return diag.row_dict(row)

    @mcp.tool()
    async def diagnose_updates(host: str) -> dict[str, Any]:
        """WHY IS A HOST BEHIND ON UPDATES, OR WHY DID AN UPDATE FAIL? Asks the host's own update diagnosis
        (`update_diagnose`, Windows Update on Windows / apt·dnf on Linux) and returns the stored document: `summary`,
        `findings` (upd.install_failed, upd.reboot_pending, upd.wsus_unreachable, upd.held, upd.dpkg_interrupted,
        upd.behind, upd.up_to_date — each with a certainty and evidence_ids), `evidence`, `timeline`, `gaps`, and
        `contract_status`. Same honesty rules as diagnose_service: the certainty is the agent's, measured — repeat it,
        never raise it; cite evidence ids; a remedy is a proposal, not an action. Read-only on the host."""
        from bossman.services import diagnosis as diag
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
            try:
                row = await diag.diagnose_updates(session, agent, client)
            except diag.DiagnosisUnavailable as exc:
                raise ValueError(str(exc)) from exc
            return diag.row_dict(row)

    @mcp.tool()
    async def recent_diagnoses(host: str, name: str = "", limit: int = 10) -> dict[str, Any]:
        """The diagnoses already stored for a host (optionally one service), newest first, without the documents:
        when, which service, status, leading rule + certainty, summary, contract_status. Use it to see whether a
        problem is new or recurring before asking for a fresh diagnose_service."""
        from bossman.services import diagnosis as diag
        async with session_factory() as session:
            agent = await session.scalar(select(Agent).where(Agent.name == host))
            if agent is None:
                raise ValueError(f"no such host {host!r}")
            rows = await diag.recent(session, agent, name, max(1, min(limit, 100)))
            return {"host": host, "items": [diag.row_dict(r, with_document=False) for r in rows]}

    @mcp.tool()
    async def recent_diagnoses_fleet(status: str = "", contract_status: str = "", platform: str = "",
                                     q: str = "", limit: int = 50) -> dict[str, Any]:
        """Stored diagnoses across the WHOLE fleet, newest first, without the documents — the fleet-wide view, so a
        diagnosis is findable without naming a host. Each item: host, when, service, status, leading rule + certainty,
        summary, contract_status. Filters: status (running/failed/behind/…), contract_status (ok/violation — to find
        documents that did not hold), platform, q (substring on host/service/rule). Use it to scan "what is wrong
        across the fleet right now" or to find recurring problems; GET the id's document for one in full."""
        from bossman.services import diagnosis as diag
        async with session_factory() as session:
            rows = await diag.recent_all(session, limit=max(1, min(limit, 500)), status=status,
                                         contract_status=contract_status, platform=platform, q=q)
            return {"items": [diag.row_dict(r, with_document=False) for r in rows]}

    @mcp.tool()
    async def recurring_failures(limit: int = 20, within_days: int = 0) -> dict[str, Any]:
        """WHAT KEEPS BREAKING across the fleet? Stored diagnoses grouped by failure mode (leading rule), most frequent
        first — each: rule, how many times diagnosed, on how many distinct hosts, how many documents did not hold, and
        when last seen. The pattern a root cause hides behind: a rule high on both count AND hosts is a fleet-wide
        cause worth fixing once. `within_days` limits to recent history (0 = all). Follow a rule into the detail with
        recent_diagnoses_fleet(q=<rule>)."""
        from datetime import datetime, timedelta, timezone
        from bossman.services import diagnosis as diag
        since = datetime.now(timezone.utc) - timedelta(days=within_days) if within_days > 0 else None
        async with session_factory() as session:
            return {"items": await diag.recurring(session, limit=max(1, min(limit, 200)), since=since)}

    @mcp.tool()
    async def recent_incidents(host: str, kind: str = "", image: str = "", within_minutes: int = 0,
                               limit: int = 200) -> dict[str, Any]:
        """WHAT CRASHED OR GOT OOM-KILLED ON A HOST, AND WHEN? A live read of the host's incident ring — the same
        history a diagnosis cites as svc.recent_incident (Linux: eBPF OOM kills and fatal signals; Windows: the ETW
        incident ring), newest first, for a timeline. Each incident: kind (oom-kill, fatal-signal, process-exit,
        image-crash, exception), time, pid, image, detail, source and the stable evidence_id. Nothing is stored:
        read `ring_state` (available | not_supported:<reason>), `capacity`, `persistent` and `since` — the ring is
        bounded and (on Linux) in-memory, so an empty list after a restart is a named gap, NOT "no crashes".
        Filters: kind, image, within_minutes (last N minutes, 0 = all the ring holds), limit (default 200)."""
        from bossman.services import diagnosis as diag
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
            try:
                return await diag.recent_incidents(agent, client, kind=kind, image=image,
                                                   within_minutes=within_minutes, limit=limit)
            except diag.DiagnosisUnavailable as exc:
                raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def export_diagnosis(id: str, format: str) -> dict[str, Any]:
        """A stored diagnosis (the `id` diagnose_service returned) in another tool's format: `checkmk`, `gelf`,
        `ansible`, `dsc` or `powershell`. The last three carry the remedies as `apply` and their `rollback`; what a
        format cannot express is in `not_expressible`, with the reason. Nothing is executed — show it to a person."""
        from bossman.db.models import Diagnosis
        from bossman.services import diagnosis_export as dx
        async with session_factory() as session:
            try:
                row = await session.get(Diagnosis, UUID(id))
            except ValueError as exc:
                raise ValueError(f"not a diagnosis id: {id!r}") from exc
            if row is None:
                raise ValueError(f"no stored diagnosis {id!r}")
            return {"id": str(row.id), **dx.export(row.document, format, row.contract_violations)}

    @mcp.tool()
    async def send_diagnosis_gelf(id: str) -> dict[str, Any]:
        """Send a stored diagnosis (`id` from diagnose_service) to the configured Graylog over GELF — one message per
        finding and per evidence, correlated by the diagnosis id. The target is BOSSMAN_GELF_HOST/_PORT/_PROTOCOL;
        with none set this refuses with the reason rather than dropping silently, and a connection error says so too.
        Read-only on the diagnosis — it changes nothing, it only forwards what export_diagnosis(format='gelf') shows."""
        from bossman.db.models import Diagnosis
        from bossman.services import diagnosis_export as dx, gelf_send
        if not settings.gelf_host:
            raise ValueError("no GELF target configured (set BOSSMAN_GELF_HOST)")
        async with session_factory() as session:
            try:
                row = await session.get(Diagnosis, UUID(id))
            except ValueError as exc:
                raise ValueError(f"not a diagnosis id: {id!r}") from exc
            if row is None:
                raise ValueError(f"no stored diagnosis {id!r}")
            messages = dx.export(row.document, "gelf", row.contract_violations)["content"]
        try:
            result = gelf_send.send(messages, settings.gelf_host, settings.gelf_port, settings.gelf_protocol)
        except (OSError, ValueError) as exc:
            raise ValueError(f"GELF send failed: {exc}") from exc
        return {"id": str(row.id), "diagnosis_id": row.diagnosis_id, **result}

    @mcp.tool()
    async def propose_remedy(id: str, finding: int = 0) -> dict[str, Any]:
        """File the remedy of one finding of a stored diagnosis (`id` from diagnose_service, `finding` its index)
        as a change proposal for a person to review. Nothing is executed — not now, not on approval: approval
        needs a second person and attaches the Ansible/DSC/PowerShell artifacts for them to run. Refused, with the
        reason, when the finding has no remedy or the diagnosis does not hold."""
        from bossman.db.models import Diagnosis
        from bossman.services import proposals as proposals_svc
        async with session_factory() as session:
            try:
                row = await session.get(Diagnosis, UUID(id))
            except ValueError as exc:
                raise ValueError(f"not a diagnosis id: {id!r}") from exc
            if row is None:
                raise ValueError(f"no stored diagnosis {id!r}")
            p = await proposals_svc.create_remedy_proposal(session, row, finding,
                                                           "ai:" + (current_identity.get() or "mcp"))
            return {"proposal_id": str(p.id), "status": p.status, "title": p.title,
                    "next": "a person reviews it under change proposals; approving executes nothing"}

    @mcp.tool()
    async def check_explanation(id: str, sentences: list[dict[str, Any]]) -> dict[str, Any]:
        """Check YOUR explanation of a stored diagnosis before you give it to a person. Pass `sentences` as
        [{"text": "...", "evidence_ids": ["..."]}]. Each comes back with `backed` and, if false, `why`: it cites no
        evidence, cites an id that is not in the diagnosis, states a certainty (the finding's certainty is not yours to
        phrase), or names a name/number/code/time that the cited evidence does not contain. Rewrite or drop every
        unbacked sentence. `header` is what must be said verbatim (certainty, claim, precedent, remedy, gaps)."""
        from bossman.db.models import Diagnosis
        from bossman.services import diagnosis_explain as dex
        async with session_factory() as session:
            try:
                row = await session.get(Diagnosis, UUID(id))
            except ValueError as exc:
                raise ValueError(f"not a diagnosis id: {id!r}") from exc
            if row is None:
                raise ValueError(f"no stored diagnosis {id!r}")
            checked = dex.check(row.document, sentences)
            return {"id": id, "header": dex.header(row.document), "sentences": checked,
                    "unbacked": sum(1 for s in checked if not s["backed"])}

    @mcp.tool()
    async def create_patch_ring(name: str, scope_type: str, accept_list: list[str] | None = None,
                                category_names: list[str] | None = None, reject_list: list[str] | None = None,
                                state: str = "installed", reboot: str = "never", agent: str = "", host_group: str = "",
                                ou: str = "", strategy: list | None = None, dry_run: bool = True) -> dict[str, Any]:
        """Plan a Windows patch ring: install updates across the fleet in ordered waves (canary → rings) with a health
        gate, as a staged rollout whose action is windows_update. `scope_type` is host|group|ou|global; name the host
        in `agent`, the group in `host_group`, the OU (name or /path) in `ou`. `state` searched|downloaded|installed;
        `accept_list` picks exact KBs (else `category_names`, default the security set); `reject_list` excludes some;
        `strategy` is the wave sizes (default [1,"25%","rest"]). Only Windows hosts are kept; others come back in
        `skipped`. NOTHING installs until the returned rollout is started — call start_rollout(rollout_id); dry_run=true
        (default) then reports what each ring would install, changing nothing. reboot never|if_required."""
        from bossman.db.models import Agent, HostGroup, OUNode
        from bossman.services import patch_ring
        from sqlalchemy import or_, select as _select
        async with session_factory() as session:
            agent_id = host_group_id = ou_id = None
            if scope_type == "host":
                a = await session.scalar(_select(Agent).where(Agent.name == agent))
                if a is None:
                    raise ValueError(f"no such host {agent!r}")
                agent_id = a.id
            elif scope_type == "group":
                g = await session.scalar(_select(HostGroup).where(HostGroup.name == host_group))
                if g is None:
                    raise ValueError(f"no such host group {host_group!r}")
                host_group_id = g.id
            elif scope_type == "ou":
                o = await session.scalar(_select(OUNode).where(or_(OUNode.name == ou, OUNode.path == ou)))
                if o is None:
                    raise ValueError(f"no such OU {ou!r} (give its name or /path)")
                ou_id = o.id
            try:
                plan = await patch_ring.plan_patch_ring(
                    session, name=name, state=state, category_names=category_names, accept_list=accept_list,
                    reject_list=reject_list, reboot=reboot, scope_type=scope_type, agent_id=agent_id,
                    host_group_id=host_group_id, ou_id=ou_id, strategy=strategy, dry_run=dry_run,
                    created_by="ai:" + (current_identity.get() or "mcp"))
            except patch_ring.PatchRingError as exc:
                raise ValueError(str(exc)) from exc
            return {"rollout_id": str(plan.rollout.id), "name": plan.rollout.name, "runbook": plan.runbook_name,
                    "waves": plan.rollout.waves, "windows_hosts": plan.windows_hosts, "skipped": plan.skipped,
                    "dry_run": dry_run, "next": "start it with start_rollout(rollout_id); nothing installs until then"}

    @mcp.tool()
    async def start_rollout(rollout_id: str) -> dict[str, Any]:
        """Start a staged rollout (a patch ring is one) — it runs its waves server-side with the health gate between
        them; returns immediately. Refused (already running) if it is already going. Poll rollout_status for progress.
        For a patch ring with dry_run=true this walks the waves reporting what each would install, changing nothing."""
        import asyncio
        from bossman.db.models import Rollout
        from bossman.services.rollout import execute_rollout
        async with session_factory() as session:
            try:
                r = await session.get(Rollout, UUID(rollout_id))
            except ValueError as exc:
                raise ValueError(f"not a rollout id: {rollout_id!r}") from exc
            if r is None:
                raise ValueError(f"no such rollout {rollout_id!r}")
            if r.status == "running":
                raise ValueError("rollout is already running — poll rollout_status")
            asyncio.create_task(execute_rollout(session_factory, settings, r.id, client_factory))
            r.status = "running"
            await session.commit()
            return {"rollout_id": rollout_id, "status": "running", "waves": r.waves,
                    "next": "poll rollout_status(rollout_id)"}

    @mcp.tool()
    async def rollout_status(rollout_id: str) -> dict[str, Any]:
        """A rollout's current state: status (pending|running|paused|done|aborted), its waves, and `progress` — the
        per-wave results so far (ok/failed counts, the health verdict). Read-only."""
        from bossman.db.models import Rollout
        async with session_factory() as session:
            try:
                r = await session.get(Rollout, UUID(rollout_id))
            except ValueError as exc:
                raise ValueError(f"not a rollout id: {rollout_id!r}") from exc
            if r is None:
                raise ValueError(f"no such rollout {rollout_id!r}")
            return {"rollout_id": rollout_id, "name": r.name, "status": r.status, "dry_run": r.dry_run,
                    "waves": r.waves, "progress": r.progress}

    @mcp.tool()
    async def abort_rollout(rollout_id: str) -> dict[str, Any]:
        """Ask a rollout to stop. It stops at the next wave boundary, not instantly — a wave already in flight finishes
        (killing it would leave hosts half-applied). Accepted while running/pending/paused; a no-op otherwise."""
        from bossman.db.models import Rollout
        async with session_factory() as session:
            try:
                r = await session.get(Rollout, UUID(rollout_id))
            except ValueError as exc:
                raise ValueError(f"not a rollout id: {rollout_id!r}") from exc
            if r is None:
                raise ValueError(f"no such rollout {rollout_id!r}")
            if r.status in ("running", "pending", "paused"):
                r.status = "aborted"
                await session.commit()
            return {"rollout_id": rollout_id, "status": r.status}

    @mcp.tool()
    async def pause_rollout(rollout_id: str) -> dict[str, Any]:
        """Pause a running rollout at the next wave boundary (a wave in flight finishes), keeping its progress; resume
        continues from the next wave. A no-op unless it is running. Use it to hold a patch ring between rings."""
        from bossman.db.models import Rollout
        async with session_factory() as session:
            try:
                r = await session.get(Rollout, UUID(rollout_id))
            except ValueError as exc:
                raise ValueError(f"not a rollout id: {rollout_id!r}") from exc
            if r is None:
                raise ValueError(f"no such rollout {rollout_id!r}")
            if r.status == "running":
                r.status = "paused"
                await session.commit()
            return {"rollout_id": rollout_id, "status": r.status}

    @mcp.tool()
    async def resume_rollout(rollout_id: str) -> dict[str, Any]:
        """Resume a paused rollout from where it stopped — the next wave, earlier waves left untouched. Refused unless
        it is paused. Returns immediately; the remaining waves run server-side. Poll rollout_status for progress."""
        import asyncio
        from bossman.db.models import Rollout
        from bossman.services.rollout import execute_rollout
        async with session_factory() as session:
            try:
                r = await session.get(Rollout, UUID(rollout_id))
            except ValueError as exc:
                raise ValueError(f"not a rollout id: {rollout_id!r}") from exc
            if r is None:
                raise ValueError(f"no such rollout {rollout_id!r}")
            if r.status != "paused":
                raise ValueError("only a paused rollout can be resumed")
            asyncio.create_task(execute_rollout(session_factory, settings, r.id, client_factory, resume=True))
            r.status = "running"
            await session.commit()
            return {"rollout_id": rollout_id, "status": "running", "next": "poll rollout_status(rollout_id)"}

    @mcp.tool()
    async def man_search(
        host: str, query: str = "", page: str = "", section: str = "", heading: str = "", grep: str = "",
        full_text: bool = False, max_chars: int = 8000, limit: int = 20,
    ) -> dict[str, Any]:
        """Look things up in the manual pages installed on a managed host — the documentation of exactly the
        versions that run there. Use it BEFORE changing a configuration you are not sure about. Two steps:
        (1) search with `query` (a few words, e.g. "ssh daemon"; full_text=true finds an option or directive name
        inside the pages, e.g. "PermitRootLogin"); (2) read with `page` (+ `section`: 5 file formats, 8 daemons and
        admin commands, 1 user commands), narrowed by `heading` (OPTIONS, FILES, EXAMPLES) or `grep` (a word — the
        paragraph that defines it comes first). A host without manual pages says so in `note`."""
        from bossman.services.manpages import man_lookup
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
        return await man_lookup(client, {"query": query, "page": page, "section": section, "heading": heading,
                                         "grep": grep, "full_text": full_text, "max_chars": max_chars,
                                         "limit": limit})

    @mcp.tool()
    async def disk_layout(host: str) -> dict[str, Any]:
        """Read a host's disks + partitions (the gparted-style Disks view),
        read-only: {devices:[{path,size_bytes,table,sector_size,partitions:[…],
        free:[…]}], vgs:[…]}. Each partition carries fstype/label/mountpoint/
        used/avail/busy and start_s/end_s sectors. This is the SCAN step — call
        it first to see the layout, then disk_plan_preview / disk_plan_apply to
        change it. Live read over the agent (lsblk + parted)."""
        from bossman.services import disk_layout as _dl
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
        return await _dl.read_disk_layout(agent, client_factory, settings)

    @mcp.tool()
    async def disk_plan_preview(host: str, ops: list[dict[str, Any]]) -> dict[str, Any]:
        """Compile a gparted-style op queue to the exact host commands + a safety
        verdict, WITHOUT running anything. Always preview before disk_plan_apply.
        `ops` is an ordered list; each op is a dict with an `op` field:
          mklabel   {op,device,table}                  new partition table (gpt|msdos)
          mkpart    {op,device,fstype,start,end,ptype}  create a partition
          mkfs      {op,device,target,fstype}           format (ext4/xfs/btrfs/vfat/swap)
          label     {op,device,target,fstype,label}     set a filesystem label
          mount     {op,device,target,mountpoint}       mkdir + mount
          umount    {op,device,target}                  unmount (frees a fs for editing)
          delete    {op,device,num}                     delete a partition
          resize    {op,device,target,num,fstype,start_mib,size_mib,grow}
                    resize an unmounted ext* partition + its fs (grow=true grows,
                    false shrinks; size_mib is the new size, start_mib its start)
          lvextend  {op,device,target,size}             grow an LV online (size like +5G)
          lvreduce  {op,device,target,size}             shrink an LV (fs shrunk first; needs
                    unmount; absolute size like 8G, not a +grow)
          -- ZFS (pools/datasets; sizing is a property, not geometry) --
          zfs_create   {op,name,mountpoint?}            create a dataset
          zfs_set      {op,name,property,size}          the ZFS "resize": property is
                       quota|refquota (logical cap) or reservation|refreservation (guaranteed);
                       online, non-destructive
          zfs_snapshot {op,name,snap,recursive?}        snapshot name@snap
          zfs_rollback {op,name}                        roll back to a name@snap (destroys newer)
          zfs_destroy  {op,name,recursive?}             destroy a dataset (guarded off critical mounts)
          zpool_create {op,name,raid?,vdevs[]}          raid: ''(stripe)|mirror|raidz|raidz2; vdevs guarded
          zpool_add    {op,name,raid?,vdevs[]}          grow a pool with more vdevs
          zpool_destroy{op,name}                        destroy a pool (guarded off critical mounts)
        Returns {steps, problems, ok}. `ok=false` means a safety error blocks apply
        (e.g. target mounted, or a non-loop disk with mounted filesystems)."""
        from bossman.services import disk_layout as _dl, disk_ops as _do
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
        layout = await _dl.read_disk_layout(agent, client_factory, settings)
        steps = _do.compile({"ops": ops})
        problems = _do.safety_check(steps, layout, allow_nonloop=True)
        return {"steps": steps, "problems": problems,
                "ok": not any(p["severity"] == "error" for p in problems)}

    @mcp.tool()
    async def disk_plan_apply(host: str, ops: list[dict[str, Any]]) -> dict[str, Any]:
        """Run a gparted-style op queue on a host (DESTRUCTIVE). Same `ops` shape as
        disk_plan_preview — preview first. The safety gate always runs and refuses:
        any disk carrying a mounted filesystem (protects the system/root disk), a
        format/label/delete/resize whose target is mounted (unmount it first), and a
        non-online lvextend. Before a partition-table change the table is dumped
        (sfdisk -d) as a rollback point; missing tools (parted/e2fsprogs/…) are
        installed best-effort. Stops at the first failed step. Returns {ok, refused,
        problems, steps:[{desc,ok,output}], table_backup}."""
        from bossman.services import disk_layout as _dl, disk_ops as _do
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
        layout = await _dl.read_disk_layout(agent, client_factory, settings)
        return await _do.apply(agent, client_factory, settings, {"ops": ops}, layout,
                               allow_nonloop=True)

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

    # ── Kubernetes objects: the AI drives a cluster through its ACCESS HOST ──
    # (project kubernetes-console). cluster = the registered Kubernetes cluster's
    # NAME; every call runs kubectl on that cluster's access host, never on etcd.
    # Reads are live; writes are server-side applies behind the approval gate.

    async def _k8s_cluster_or_raise(session: AsyncSession, cluster: str):
        from bossman.db.models import KubernetesCluster
        row = await session.scalar(select(KubernetesCluster).where(KubernetesCluster.name == cluster))
        if row is None:
            names = [c.name for c in (await session.scalars(select(KubernetesCluster))).all()]
            raise ValueError(f"no such Kubernetes cluster {cluster!r} — registered: {', '.join(names) or 'none'}")
        agent = await session.get(Agent, row.agent_id)
        if agent is None or not agent.address:
            raise ValueError(f"Kubernetes cluster {cluster!r}: its access host has no reachable address")
        return row, agent, client_factory(agent, settings)

    @mcp.tool()
    async def k8s_clusters() -> list[dict[str, Any]]:
        """The registered Kubernetes clusters: name, access host, reachability (reachable | unreachable |
        never) with the reason, server version, node/namespace counts, when last observed."""
        from bossman.db.models import KubernetesCluster
        async with session_factory() as session:
            rows = (await session.scalars(select(KubernetesCluster))).all()
            out = []
            for c in rows:
                agent = await session.get(Agent, c.agent_id)
                out.append({"name": c.name, "access_host": agent.name if agent else None, "reachability": c.reachability,
                            "unreachable_reason": c.unreachable_reason, "server_version": c.server_version,
                            "node_count": c.node_count, "namespace_count": c.namespace_count,
                            "observed_at": c.observed_at.isoformat() if c.observed_at else None})
            return out

    @mcp.tool()
    async def k8s_inventory(cluster: str, refresh: bool = False) -> dict[str, Any]:
        """A cluster's inventory — nodes, namespaces (with Pod Security labels), api-resources, a per-namespace
        workload summary and the latest Warning events — from Bossman's cache (poller-refreshed every 15 min).
        refresh=true fetches live. Start here before listing objects."""
        from datetime import datetime, timezone
        from bossman.services import kubernetes as k
        async with session_factory() as session:
            row, _agent, client = await _k8s_cluster_or_raise(session, cluster)
            if refresh or not row.inventory:
                result = await k.refresh_inventory(session, row, client, datetime.now(timezone.utc))
                await session.commit()
                if not result.get("ok"):
                    return {"reachability": "unreachable", "reason": result.get("reason"), "inventory": row.inventory or None}
            return {"reachability": row.reachability, "observed_at": row.observed_at.isoformat() if row.observed_at else None,
                    "inventory": row.inventory}

    @mcp.tool()
    async def k8s_objects(cluster: str, kind: str, namespace: str = "", all_namespaces: bool = False,
                          selector: str = "") -> dict[str, Any]:
        """List objects of one kind (kubectl resource name: pods, deployments, svc, configmaps, …) as rows with an
        EXHAUSTIVE state (healthy | progressing | degraded | failed | completed | suspended | pending | terminating |
        unknown | static), the Kubernetes reason and its plain-language explanation and fix. Live."""
        from bossman.services import kubernetes as k
        async with session_factory() as session:
            row, _agent, client = await _k8s_cluster_or_raise(session, cluster)
            return await k.list_objects(client, row, kind, namespace=namespace or None, all_namespaces=all_namespaces,
                                        selector=selector or None)

    @mcp.tool()
    async def k8s_object(cluster: str, kind: str, name: str, namespace: str = "") -> dict[str, Any]:
        """One object with spec (desired) and status (observed) separated, its state, generation vs
        observedGeneration, field managers and the etcd key it is stored under (informational)."""
        from bossman.services import kubernetes as k
        async with session_factory() as session:
            row, _agent, client = await _k8s_cluster_or_raise(session, cluster)
            return await k.get_object(client, row, kind, name, namespace=namespace or None)

    @mcp.tool()
    async def k8s_events(cluster: str, namespace: str = "", name: str = "", kind: str = "",
                         all_namespaces: bool = False) -> dict[str, Any]:
        """Events — the WHY behind a state — for a namespace or one object (name + kind), Warnings first,
        newest first, each Warning explained. Read this before deciding what to change."""
        from bossman.services import kubernetes as k
        async with session_factory() as session:
            row, _agent, client = await _k8s_cluster_or_raise(session, cluster)
            return await k.events_for(client, row, namespace or None, name=name or None, kind=kind or None,
                                      all_namespaces=all_namespaces)

    @mcp.tool()
    async def k8s_logs(cluster: str, namespace: str, pod: str, container: str = "", tail: int = 200,
                       previous: bool = False) -> dict[str, Any]:
        """A container's last `tail` log lines. previous=true reads the crashed predecessor — the first thing
        to read on CrashLoopBackOff."""
        from bossman.services import kubernetes as k
        async with session_factory() as session:
            row, _agent, client = await _k8s_cluster_or_raise(session, cluster)
            return await k.logs(client, row, namespace, pod, container=container or None, tail=tail, previous=previous)

    def _k8s_resource(session, row, agent, manifest: dict[str, Any], requested_by: str = "mcp"):
        from bossman.services.resources.kubernetes_object import KubernetesObjectResource
        md = manifest.get("metadata") or {}
        if not manifest.get("kind") or not md.get("name"):
            raise ValueError("manifest needs kind and metadata.name")
        return KubernetesObjectResource(session, agent, client_factory, settings, md["name"], cluster=row,
                                        namespace=md.get("namespace") or None, api_version=manifest.get("apiVersion") or "v1",
                                        kind=manifest["kind"], requested_by=requested_by)

    @mcp.tool()
    async def k8s_plan(cluster: str, manifest: dict[str, Any]) -> dict[str, Any]:
        """What applying this manifest WOULD do: a server-side dry run (admission, validation, Pod Security,
        quota — nothing persisted) plus the diff. action = create | update | noop | refused (with the server's
        reason). Always call before k8s_apply."""
        async with session_factory() as session:
            row, agent, _client = await _k8s_cluster_or_raise(session, cluster)
            return await _k8s_resource(session, row, agent, manifest).plan({"manifest": manifest})

    @mcp.tool()
    async def k8s_apply(cluster: str, manifest: dict[str, Any], dry_run: bool = True, note: str = "") -> dict[str, Any]:
        """Server-side apply of one object's manifest (field manager "bossman", strict validation), recorded as a
        Bossman generation. dry_run defaults to true. Outside global YOLO mode this files a ChangeProposal
        with the preview instead of applying — the answer says awaiting_approval and names the proposal for a
        human to approve. Rollback = k8s_rollback with a generation from the answer's history."""
        async with session_factory() as session:
            row, agent, _client = await _k8s_cluster_or_raise(session, cluster)
            return await _k8s_resource(session, row, agent, manifest, requested_by="ai:mcp").apply(
                {"manifest": manifest, "require_approval": True}, dry_run=dry_run, note=note or None)

    @mcp.tool()
    async def k8s_generations(cluster: str, kind: str, name: str, namespace: str = "", api_version: str = "v1") -> dict[str, Any]:
        """Bossman's history of applied manifests for one object (rollback points). Kubernetes' own rollout
        revisions are a separate numbering — see k8s_object."""
        async with session_factory() as session:
            row, agent, _client = await _k8s_cluster_or_raise(session, cluster)
            r = _k8s_resource(session, row, agent, {"apiVersion": api_version, "kind": kind, "metadata": {"name": name, "namespace": namespace or None}})
            return {"resource_key": r.resource_key, "generations": await r.generations()}

    @mcp.tool()
    async def k8s_rollback(cluster: str, kind: str, name: str, generation: int, namespace: str = "", api_version: str = "v1") -> dict[str, Any]:
        """Re-apply an earlier generation's manifest as a NEW generation (forward-converge), through the same
        approval gate as k8s_apply. Rolling back to a generation that recorded a deletion deletes again."""
        async with session_factory() as session:
            row, agent, _client = await _k8s_cluster_or_raise(session, cluster)
            r = _k8s_resource(session, row, agent, {"apiVersion": api_version, "kind": kind, "metadata": {"name": name, "namespace": namespace or None}}, requested_by="ai:mcp")
            return await r.rollback(generation)

    @mcp.tool()
    async def k8s_delete(cluster: str, kind: str, name: str, namespace: str = "", api_version: str = "v1",
                         preview: bool = True) -> dict[str, Any]:
        """Delete one object. preview=true (default) only lists what goes with it (dependents by ownerReference)
        and what STAYS (PersistentVolumeClaims, with the reason). preview=false deletes and records the deletion
        as a generation, so the object shows as vanished in its history."""
        async with session_factory() as session:
            row, agent, _client = await _k8s_cluster_or_raise(session, cluster)
            r = _k8s_resource(session, row, agent, {"apiVersion": api_version, "kind": kind, "metadata": {"name": name, "namespace": namespace or None}}, requested_by="ai:mcp")
            return await r.delete(preview=preview)

    # --- Systems / rehearsal plane (clone-a-prod-system, AI-autonomous) -------

    async def _system_by_name_or_raise(session: AsyncSession, name: str):
        from bossman.db.models import System
        s = (await session.scalars(select(System).where(System.name == name))).first()
        if s is None:
            raise ValueError(f"no such system: {name!r} (use system_list)")
        return s

    @mcp.tool()
    async def windows_event_log(
        host: str,
        levels: str = "critical,error,warning",
        logs: str = "System,Application",
        since: str = "24h",
        provider: str = "",
        contains: str = "",
        max_events: int = 200,
    ) -> dict[str, Any]:
        """Read a Windows host's event log, filtered ON THE HOST — the first place to look when a Windows
        machine misbehaves.

        `levels` are CANONICAL ENGLISH NAMES: critical, error, warning, information, verbose, log_always.
        Use them, not the host's own words: LevelDisplayName is LOCALISED (a German host says "Fehler",
        "Warnung") and measurably sometimes EMPTY, so filtering on what the host calls a level finds nothing
        on half the fleet. Every event comes back with all three — `level` (Windows' number, authoritative),
        `level_name` (canonical, what you should read and filter on) and `level_display` (the host's word).

        The default "critical,error,warning" is what "show me the problems" means, and it deliberately
        includes ERROR — the commonest of the three by far, and the one a "warnings and critical" filter
        would silently drop.

        `logs` selects the categories. A Server 2022 has 406 channels of which ~83 hold anything, so start
        from windows_event_log_channels(host) rather than guessing: the fullest channel on a fresh install is
        a diagnostic one with 22 000 records nobody asked for.

        `since` takes a duration ("24h", "7d", "30m") or an ISO timestamp. The reply carries `by_level` and
        `by_provider` counts (so "who is producing these" needs no second call) and `capped` — READ IT: a
        capped answer is a floor, not a total, and concluding "only 200 errors" from a cap is worse than
        being told the number is incomplete.

        Read-only, and available even when the host's write gate is closed."""
        params: dict[str, Any] = {
            "levels": levels, "logs": logs, "since": since, "max_events": max_events,
        }
        if provider:
            params["provider"] = provider
        if contains:
            params["contains"] = contains
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
        # The log service answers a filtered query in milliseconds, but a wide window over a large channel is
        # a real read — give it more than the 30-second default rather than reporting a timeout as a failure.
        client._timeout = 180.0  # noqa: SLF001 — one construction path, see agent_client.client_for
        try:
            return await client.call_tool("windows_eventlog", params)
        except AgentClientError as exc:
            raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def windows_event_log_channels(host: str, only_with_records: bool = True,
                                        name_like: str = "") -> dict[str, Any]:
        """List a Windows host's event log CATEGORIES with their record counts, size and retention — what to
        pick from before reading anything.

        406 channels exist on a Server 2022 and about 83 hold records, so `only_with_records` defaults to
        true and the list is sorted by count. `retention` (Circular | AutoBackup | Retain) is the field that
        says whether "the event is not there" means "it never happened" or "it has already rotated away"."""
        params: dict[str, Any] = {"only_with_records": only_with_records}
        if name_like:
            params["name_like"] = name_like
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
        client._timeout = 180.0  # noqa: SLF001
        try:
            return await client.call_tool("windows_eventlog_channels", params)
        except AgentClientError as exc:
            raise ValueError(str(exc)) from exc

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

    async def _make_resource(session, host: str, kind: str, name: str, namespace: str = "default",
                             cluster: str = "", api_version: str = "", object_kind: str = ""):
        """The ONE construction path, shared with the REST routes: services.resources.build reads the
        registry. This used to be a private if-chain that knew only docker|helm|config|role, so package,
        service, k8s (and later tunable) existed over REST but not over MCP — two ways to the same object,
        and one of them incomplete."""
        import types as _types

        from bossman.services import resources as _reg

        try:
            _reg.spec_for(kind)
        except ValueError as exc:
            raise ValueError(str(exc)) from exc
        agent = await session.scalar(select(Agent).where(Agent.name == host))
        if agent is None:
            raise ValueError(f"no such host {host!r}")
        await _authorize_host(session, agent)
        identity = _types.SimpleNamespace(name=current_identity.get() or "mcp")
        try:
            return await _reg.build(kind, agent_id=agent.id, name=name, session=session, settings=settings,
                                    client_factory=client_factory, identity=identity, namespace=namespace,
                                    cluster=cluster, api_version=api_version, object_kind=object_kind)
        except (_reg.NoSuchResource, _reg.ResourceUnreachable) as exc:
            raise ValueError(str(exc)) from exc

    @mcp.tool()
    async def resource_observe(host: str, kind: str, name: str, namespace: str = "default", cluster: str = "",
                               api_version: str = "", object_kind: str = "") -> dict[str, Any]:
        """Observe a Resource's current state, with its schema. kind = config|docker|helm|k8s|package|role|
        service|tunable; a tunable is named <tunable>[:<target>] (sched_ext, cpu_governor, kernel_cmdline,
        systemd_resource:<unit>, blockdev_tuning:<device>)."""
        from bossman.services import resources as _reg

        async with session_factory() as session:
            r = await _make_resource(session, host, kind, name, namespace, cluster, api_version, object_kind)
            spec = _reg.spec_for(kind)
            schema = None
            if spec.has_schema or spec.observe_includes_schema:
                schema = await r.schema_async() if (spec.schema_is_async or spec.observe_includes_schema) else r.schema()
            return {"resource_key": r.resource_key, "observed": await r.observe(), "schema": schema}

    @mcp.tool()
    async def resource_plan(host: str, kind: str, name: str, desired: dict[str, Any], namespace: str = "default",
                            cluster: str = "", api_version: str = "", object_kind: str = "") -> dict[str, Any]:
        """Diff a desired spec against the observed state (no write). desired for docker =
        {image,ports,env,volumes,restart}; helm = {chart,values}; package = {state,version}; service =
        {enabled,state}; tunable = {params:{...the yoloman.<tunable> module's parameters}} — its plan
        carries before/after, persistence (live|persistent|pending_reboot) and the undo, or
        action=refused with refusal.kind unsupported|tool_unavailable|conflict and the reason."""
        async with session_factory() as session:
            r = await _make_resource(session, host, kind, name, namespace, cluster, api_version, object_kind)
            return await r.plan(desired)

    @mcp.tool()
    async def resource_apply(host: str, kind: str, name: str, desired: dict[str, Any],
                             dry_run: bool = True, note: str | None = None, namespace: str = "default",
                             cluster: str = "", api_version: str = "", object_kind: str = "") -> dict[str, Any]:
        """Apply a desired spec (records a generation). dry_run=true returns the
        plan without writing — preview first for anything non-trivial."""
        async with session_factory() as session:
            r = await _make_resource(session, host, kind, name, namespace, cluster, api_version, object_kind)
            return await r.apply(desired, dry_run=dry_run, note=note)

    @mcp.tool()
    async def resource_generations(host: str, kind: str, name: str, namespace: str = "default", cluster: str = "",
                                   api_version: str = "", object_kind: str = "") -> list[dict[str, Any]]:
        """The Resource's applied-generation history (rollback points)."""
        async with session_factory() as session:
            r = await _make_resource(session, host, kind, name, namespace, cluster, api_version, object_kind)
            return await r.generations()

    @mcp.tool()
    async def resource_rollback(host: str, kind: str, name: str, generation: int, namespace: str = "default",
                                cluster: str = "", api_version: str = "", object_kind: str = "") -> dict[str, Any]:
        """Roll a Resource back to an earlier generation (re-applied as a NEW
        generation — forward-converge, uniform across tiers). For a tunable, generation 0 is
        the named state "before yoloman managed it": generation 1's recorded undo is applied."""
        async with session_factory() as session:
            r = await _make_resource(session, host, kind, name, namespace, cluster, api_version, object_kind)
            return await r.rollback(generation)

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
            await _authorize_host(session, agent)

            # From the DATABASE, GPO-merged (see services/scope_vars) — the filesystem host_vars layer is
            # gone; it was a second source for the same fact.
            host_vars = await resolve_scope_vars(session, agent)
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
        the cause, preview the fix, apply it.

        GOVERNANCE: an apply (dry_run=false) does NOT write directly unless the
        fleet is in YOLO mode — it files a CHANGE PROPOSAL carrying this diff for
        a human to approve. The tool returns {proposed: true, proposal_id, diff}
        in that case; the change takes effect only once a human approves it."""
        resource = {"type": "config", "path": path, "format": config_format,
                    "separator": separator, "values": values}
        async with session_factory() as session:
            agent = await _addressed_agent_or_raise(session, host)
            client = client_factory(agent, settings)
            # A pure preview always just runs check_mode.
            if dry_run:
                try:
                    return await client.state_apply({"resources": [resource]}, True)
                except AgentClientError as exc:
                    raise ValueError(str(exc)) from exc
            # An APPLY is human-gated unless YOLO: capture the diff, then either
            # apply directly (YOLO) or file a proposal for approval.
            if await is_yolo_mode(session):
                try:
                    return await client.state_apply({"resources": [resource]}, False)
                except AgentClientError as exc:
                    raise ValueError(str(exc)) from exc
            try:
                preview = await client.state_apply({"resources": [resource]}, True)
            except AgentClientError as exc:
                raise ValueError(str(exc)) from exc
            from bossman.services import proposals as proposals_svc

            actor = current_identity.get()
            requested_by = f"ai:{actor}" if actor else "ai:mcp"
            p = await proposals_svc.create_config_proposal(
                session, agent, [resource], preview, requested_by,
                title=f"Set {path} on {agent.name}")
            return {"proposed": True, "proposal_id": str(p.id), "status": "pending",
                    "message": "change filed as a proposal — awaiting human approval",
                    "diff": preview}

    @mcp.tool()
    async def set_config_policy(
        path: str,
        values: dict[str, Any],
        ou: str = "",
        group: str = "",
        config_format: str = "keyvalue",
        separator: str = "",
        dry_run: bool = True,
    ) -> dict[str, Any]:
        """Author a config policy at OU or GROUP scope (K4) — the wide-scope sibling of set_host_config: it converges
        `path` toward `values` on EVERY host in the scope, like linking a GPO. Name the scope with `ou` (an OU path,
        e.g. "/Munich") OR `group` (a host-group name) — exactly one. `values` is the desired key→value map (its codec
        is `config_format`: keyvalue|ini|…; `separator` for keyvalue); a null value enforces a key's absence.

        dry_run=true (default) PREVIEWS — each member host gets a check-mode apply and nothing is persisted; always
        preview first. An apply (dry_run=false) changes many hosts at once, so it is GOVERNANCE-gated: it proceeds only
        when the fleet is in YOLO mode; otherwise it is refused (with the preview) and you are told to author it in the
        Policy console, where a human owns a fleet-wide change. Use the preview to show the blast radius first."""
        from bossman.api.ou import ConfigPolicyError, author_config_policy

        if bool(ou) == bool(group):
            raise ValueError("name exactly one scope: `ou` (an OU path) or `group` (a host-group name)")
        async with session_factory() as session:
            scope_ou_id = scope_group_id = None
            if ou:
                row = await session.scalar(select(OUNode).where(OUNode.path == ou))
                if row is None:
                    raise ValueError(f"no OU at path {ou!r}")
                scope_ou_id = row.id
            else:
                row = await session.scalar(select(HostGroup).where(HostGroup.name == group))
                if row is None:
                    raise ValueError(f"no host group named {group!r}")
                scope_group_id = row.id

            # An apply to many hosts is human-gated unless the fleet opted into autonomy (YOLO).
            if not dry_run and not await is_yolo_mode(session):
                try:
                    preview = await author_config_policy(
                        session, settings, client_factory, scope_ou_id=scope_ou_id, host_group_id=scope_group_id,
                        path=path, format=config_format, separator=separator, values=values, dry_run=True)
                except ConfigPolicyError as exc:
                    raise ValueError(str(exc)) from exc
                return {"applied": False, "reason": "a fleet-wide config policy is not applied via MCP outside YOLO "
                        "mode — author it in the Policy console, where a human owns the change", "preview": preview}
            try:
                return await author_config_policy(
                    session, settings, client_factory, scope_ou_id=scope_ou_id, host_group_id=scope_group_id,
                    path=path, format=config_format, separator=separator, values=values, dry_run=dry_run)
            except ConfigPolicyError as exc:
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
            await _authorize_host(session, agent)

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
            # Attribute AI-driven runs so the Event Browser answers "who commissioned
            # the AI": prefix the human identity with "ai:" (the MCP facade is how
            # the chat/agent acts on a user's behalf). Falls back to a bare marker
            # when no identity is bound (e.g. a system MCP client).
            _actor = current_identity.get()
            _requested_by = f"ai:{_actor}" if _actor else "ai:mcp"
            _run_row, rr = await runbook_exec.execute_runbook(
                session, agent, doc, settings=settings, client=client,
                request_vars=variables or {}, dry_run=check_mode,
                requested_by=_requested_by, commit=True,
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
    async def qualify_package(name: str, force: bool = False) -> dict[str, Any]:
        """Create ALL config artifacts for a package — codec classification,
        per-directive value catalog, the Jinja2 template + values schema, and enum
        enrichment — then categorize it into the package catalog (einsortiert).

        Runs the SAME pipeline the host batch uses (bossman.tools.qualify_packages +
        build_package_catalog), against the RW-mounted configs and Bossman's
        CONFIGURED AI endpoint. Use this to onboard a new package/service so it shows
        up in the wizard, Roles & Features and the gpedit config editor. Takes a
        couple of minutes.

        Returns what the run DID: `already_current` (every marker was up to date, so
        nothing ran — pass force=True to rebuild anyway), the codec it classified, how
        many enums and directives it mined, whether the Lego enrich gates passed, the
        assigned category, and `detail` — the reason behind a skip, a failure or a
        gate that stopped the enrich step. The pipeline's progress output goes to
        Bossman's log rather than into this reply."""
        from bossman.api.package_qualify import run_qualify

        res = await run_qualify(name, force=force)
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

    reject_unknown_arguments(mcp)
    return mcp


def reject_unknown_arguments(mcp: FastMCP) -> None:
    """Every tool refuses an argument it does not declare, instead of dropping it silently.

    FastMCP's argument models ignore extra keys: `call_agent_tool(..., arguments={...})` (the field is `params`) ran
    with no params at all and failed later with a misleading "missing required parameter" from the agent (measured
    2026-10-18). Now the call fails at once, names the unknown key, the closest declared one and all declared ones,
    and each tool's input schema says `additionalProperties: false` so a client can know before calling."""
    import difflib

    for tool in mcp._tool_manager.list_tools():
        meta = tool.fn_metadata
        declared = {f.alias or name for name, f in meta.arg_model.model_fields.items()}
        if isinstance(tool.parameters, dict):
            tool.parameters["additionalProperties"] = False
        original = meta.call_fn_with_arg_validation

        async def checked(fn, fn_is_async, arguments_to_validate, arguments_to_pass_directly,
                          _original=original, _declared=declared, _name=tool.name):
            unknown = sorted(set(arguments_to_validate or {}) - _declared)
            if unknown:
                hints = []
                for key in unknown:
                    close = difflib.get_close_matches(key, sorted(_declared), n=1, cutoff=0.5)
                    hints.append(f"{key!r}" + (f" (did you mean {close[0]!r}?)" if close else ""))
                raise ValueError(f"{_name}: unknown parameter {', '.join(hints)}; it takes: {', '.join(sorted(_declared))}")
            return await _original(fn, fn_is_async, arguments_to_validate, arguments_to_pass_directly)

        object.__setattr__(meta, "call_fn_with_arg_validation", checked)
