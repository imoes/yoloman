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
    {
        "type": "function",
        "function": {
            "name": "capability_match",
            "description": (
                "For a host, find what its unmet service requirements need and WHICH other hosts in the "
                "inventory provide them (the deterministic Lego matcher — e.g. 'this Roundcube needs a "
                "database; host db1 provides mysql'). Returns per requirement: the capability + accepted "
                "backends, matching provider hosts with a ready field wiring (db_host=…, db_port=…), and — "
                "when nothing provides it yet — the catalog role a NEW server would need. Use it when the "
                "user asks what a server needs, what connects to what, or how to wire two systems."
            ),
            "parameters": {
                "type": "object",
                "properties": {"host": {"type": "string", "description": "The host (agent) name."}},
                "required": ["host"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_help",
            "description": (
                "Search the yolo-man documentation (README + docs) for how the product works — "
                "modules, checks, OU/Policy, discovery, the NestedText format, etc. Use this when "
                "the user asks how something works, OR whenever you are unsure how to do something "
                "in yolo-man before answering. Returns the most relevant doc sections."
            ),
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string", "description": "What to look up."}},
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "discover_host_checks",
            "description": (
                "Run monitoring auto-discovery on a host: detect which checks apply and the "
                "items/metrics they'd monitor (e.g. a MySQL server, filesystems, sensors). Returns "
                "proposals, each with `needs_params` — required parameters (often CREDENTIALS) with "
                "no default. IMPORTANT: before assigning a proposed check that has non-empty "
                "needs_params, you MUST ASK THE USER for those values (never invent them). Then "
                "call assign_host_check with the collected parameters."
            ),
            "parameters": {
                "type": "object",
                "properties": {"host": {"type": "string", "description": "The host (agent) name."}},
                "required": ["host"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "assign_host_check",
            "description": (
                "Assign a check to a host with parameters (host-scoped). Call this only AFTER the "
                "user has provided any required parameters/credentials the check needs "
                "(see discover_host_checks' needs_params). Creates the monitoring assignment."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "host": {"type": "string"},
                    "check_name": {"type": "string"},
                    "parameters": {"type": "object", "description": "Parameter values for the check (incl. any credentials the user provided)."},
                },
                "required": ["host", "check_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "analyze_host",
            "description": (
                "Investigate a host to find the SOURCE of a problem. Returns the host's recent "
                "journald errors (priority err+), error-ish lines from key /var/log files "
                "(syslog/kern/daemon/auth/…), failed systemd services, and the latest eBPF/"
                "service/resource metrics. Call this whenever the user reports a problem (e.g. "
                "'we have database problems', 'X is slow/failing') to gather EVIDENCE, then present "
                "a root-cause analysis with concrete recommendations. Use read_host_log to drill "
                "into any log it flags. If the user says WHEN the error occurred, pass `since` to "
                "focus the journal on that window; otherwise omit it to get the full recent picture."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "host": {"type": "string", "description": "The host (agent) name."},
                    "since": {"type": "string", "description": "Optional journalctl time spec to focus on when the error occurred, e.g. '-2h', '2026-07-12 14:00', 'yesterday'."},
                },
                "required": ["host"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "bossman_guide",
            "description": (
                "START HERE when unsure how to operate Bossman. Returns the operator skill: the mental "
                "model (read-first; writes are dry-run + human-gated) and, per DevOps task, which action "
                "to take — inspect a host/fleet, configure ONE host vs MANY via a policy, monitoring & "
                "thresholds, playbooks/runbooks, provisioning. Read it before planning a multi-step change."
            ),
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "host_status",
            "description": "Quick descriptor of ONE host: mode, enrollment state, online, address, tags/groups and OU. Use for a fast 'what/where is this host' before deeper triage (analyze_host) or changes.",
            "parameters": {
                "type": "object",
                "properties": {"host": {"type": "string", "description": "The host (agent) name."}},
                "required": ["host"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_problems",
            "description": "List active fleet problems — non-OK services in a hard state, most recent first (the 'unhandled problems' triage view). Each: host, service, state, value, thresholds, acknowledged, in_downtime. Call this to see what needs attention across the fleet.",
            "parameters": {
                "type": "object",
                "properties": {"state": {"type": "string", "description": "Optional filter: WARN | CRIT | UNKNOWN."}},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_runbooks",
            "description": "List stored runbooks (multi-step procedures / playbooks), optionally by folder (e.g. 'wizards' for install-<pkg>). Each carries its typed parameters. Use to find a procedure to run; running one is a gated write done via the MCP/REST path.",
            "parameters": {
                "type": "object",
                "properties": {"folder": {"type": "string", "description": "Optional folder filter, e.g. 'wizards'."}},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_checks",
            "description": "Find monitoring checks by what they do: name, short_description, one-paragraph summary, category and datasource (agent|snmp|ssh). Pass `query` to filter (e.g. 'cpu','disk','postgres'). Use to discover which check to assign to a host (then discover_host_checks / assign_host_check).",
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string", "description": "Optional substring filter over name/description."}},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_host_log",
            "description": (
                "Tail one /var/log file on a host to drill into a log analyze_host flagged. "
                "Filter with `grep`: a plain substring, an extended regex when regex=true (grep -E), "
                "inverted when invert=true (grep -v). Path-jailed to /var/log — read-only."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "host": {"type": "string"},
                    "path": {"type": "string", "description": "Absolute log path under /var/log."},
                    "grep": {"type": "string", "description": "Optional pattern (substring, or regex if regex=true)."},
                    "regex": {"type": "boolean", "description": "Treat grep as an extended regex (grep -E). Default false."},
                    "invert": {"type": "boolean", "description": "Keep lines that do NOT match grep (grep -v). Default false."},
                    "lines": {"type": "integer", "description": "Trailing lines (default 200)."},
                },
                "required": ["host", "path"],
            },
        },
    },
]

TOOL_NAMES = {t["function"]["name"] for t in TOOL_DEFS}


def _online(agent: Agent, now: datetime) -> bool:
    return bool(agent.last_seen_at and agent.last_seen_at >= now - _ONLINE_WINDOW)


async def execute_tool(
    session: AsyncSession,
    name: str,
    args: dict[str, Any],
    *,
    settings: Any = None,
    client_factory: Any = None,
) -> dict[str, Any]:
    """Run one fleet tool in-process and return a JSON-serializable result.
    Unknown tools return an error dict (the model sees it and can recover).
    `settings`/`client_factory` are needed only by the discovery tools (they
    reach the host); read-only fleet tools work without them."""
    now = datetime.now(timezone.utc)
    if name == "search_help":
        from bossman.services import help as help_svc

        root = getattr(settings, "help_root", "/etc/bossman/help") if settings else "/etc/bossman/help"
        return {"query": args.get("query", ""), "results": help_svc.search_help(root, args.get("query", ""))}
    if name in ("discover_host_checks", "assign_host_check"):
        return await _check_tool(session, name, args, settings, client_factory)
    if name in ("analyze_host", "read_host_log"):
        return await _analysis_tool(session, name, args, settings, client_factory)
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
    if name == "capability_match":
        return await _capability_match(session, args, settings)
    if name == "bossman_guide":
        from bossman.services.ops_guide import BOSSMAN_GUIDE

        return {"guide": BOSSMAN_GUIDE}
    if name == "host_status":
        agent = await _resolve_agent(session, args.get("host") or "")
        if agent is None:
            return {"error": f"no such host {args.get('host')!r}"}
        return {
            "name": agent.name, "mode": agent.mode, "enrollment_state": agent.enrollment_state,
            "online": _online(agent, now), "address": agent.address,
            "groups": list(agent.groups or []), "ou_id": str(agent.ou_id) if agent.ou_id else None,
            "last_seen": agent.last_seen_at.isoformat() if agent.last_seen_at else None,
        }
    if name == "list_problems":
        from bossman.services.monitoring import query_problems

        views = await query_problems(session, state=(args.get("state") or None))
        return {"problems": [
            {"host": v.agent_name, "service": v.service.name, "state": v.service.state,
             "value": v.service.value, "warn": v.warn_threshold, "crit": v.crit_threshold,
             "acknowledged": v.service.acknowledged, "in_downtime": v.in_downtime}
            for v in views
        ]}
    if name == "list_runbooks":
        from bossman.db.models import Runbook

        q = select(Runbook)
        folder = args.get("folder")
        if folder:
            q = q.where(Runbook.folder == folder)
        rows = (await session.scalars(q.order_by(Runbook.name))).all()
        return {"runbooks": [
            {"name": r.name, "kind": r.kind, "folder": r.folder or "",
             "steps": len((r.doc or {}).get("steps", [])), "parameters": (r.doc or {}).get("parameters", {})}
            for r in rows
        ]}
    if name == "list_checks":
        from bossman.services import checks_library

        root = getattr(settings, "checks_dir", None) if settings else None
        if not root:
            return {"error": "check catalog is not available in this chat context"}
        rows = checks_library.list_checks(root)
        query = (args.get("query") or "").strip().lower()
        if query:
            rows = [r for r in rows if query in (r.get("name", "") + " " + r.get("short_description", "") + " " + r.get("summary", "")).lower()]
        return {"checks": rows}
    return {"error": f"unknown tool {name!r}"}


async def _capability_match(session: AsyncSession, args: dict, settings: Any) -> dict[str, Any]:
    """The Lego matcher for the chat AI — same deterministic logic as the REST /capabilities/match and the
    MCP capability_match tool (one logic, three surfaces)."""
    from bossman.services import capabilities as C

    if settings is None:
        return {"error": "capability matching is not available in this chat context"}
    agent = await _resolve_agent(session, args.get("host") or "")
    if agent is None:
        return {"error": f"no such host {args.get('host')!r}"}
    consumer_addr = C._agent_address(agent)
    out: list[dict[str, Any]] = []
    for req in await C.open_requirements(session, agent.id):
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
            entry["candidate_roles"] = C.roles_providing(settings, req.capability,
                                                          backends[0] if backends else None)
        out.append(entry)
    return {"host": agent.name, "requirements": out}


async def _resolve_agent(session: AsyncSession, host: str) -> Agent | None:
    return await session.scalar(select(Agent).where(Agent.name == host))


async def _analysis_tool(session, name, args, settings, client_factory) -> dict[str, Any]:
    """analyze_host / read_host_log — the AI's error-investigation tools. They
    reach the host, so they need settings + client_factory (wired by the chat
    path). Read-only: gather signals / tail a log, never mutate."""
    from bossman.services.agent_client import AgentClientError
    from bossman.services.error_analysis import gather_signals

    if settings is None or client_factory is None:
        return {"error": "host-reaching tools are not available in this chat context"}
    host = args.get("host") or ""
    agent = await _resolve_agent(session, host)
    if agent is None:
        return {"error": f"no such host {host!r}"}
    if not agent.address:
        return {"error": f"host {host!r} has no direct address (satellite/unenrolled)"}
    client = client_factory(agent, settings)
    try:
        if name == "analyze_host":
            return await gather_signals(session, agent, client, since=(args.get("since") or None))
        # read_host_log
        call: dict[str, Any] = {
            "state": "read", "path": args.get("path", ""),
            "lines": int(args.get("lines") or 200),
        }
        if args.get("grep"):
            call["grep"] = args["grep"]
            if args.get("regex"):
                call["regex"] = True
            if args.get("invert"):
                call["invert"] = True
        res = await client.call_tool("logfiles", call)
        return res.get("data", res) if isinstance(res, dict) else {"error": "unexpected result"}
    except AgentClientError as exc:
        return {"error": str(exc)}


async def _check_tool(session, name, args, settings, client_factory) -> dict[str, Any]:
    """discover_host_checks / assign_host_check (Block G9-P4). Needs settings
    + client_factory (the host-reaching tools); returns an error dict if the
    chat path didn't wire them."""
    from uuid import UUID

    from bossman.db.models import CheckAssignment
    from bossman.services import checks_library, provisioning
    from bossman.services.discovery import run_check_discovery

    DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")
    host = args.get("host") or ""
    agent = await _resolve_agent(session, host)
    if agent is None:
        return {"error": f"no such host {host!r}"}

    if name == "discover_host_checks":
        if settings is None or client_factory is None:
            return {"error": "discovery is not available in this chat context"}
        if not agent.address:
            return {"error": f"host {host!r} has no address to reach"}
        catalog = {c["name"]: c for c in checks_library.list_checks(settings.checks_dir)}
        checks = []
        for cname, entry in catalog.items():
            nt_path, star_path = checks_library.check_paths(settings.checks_dir, cname)
            try:
                checks.append({"name": cname, "star": star_path.read_text(encoding="utf-8"),
                               "sidecar": nt_path.read_text(encoding="utf-8"), "sidecar_format": "nt",
                               "options": entry.get("options", {}), "short_description": entry.get("short_description", "")})
            except OSError:
                continue
        proposals = await run_check_discovery(client_factory(agent, settings), checks)
        return {"host": host, "proposals": [
            {**p.to_dict(),
             "provisioning_available": provisioning.load_recipe(settings.checks_dir, p.check_name) is not None}
            for p in proposals
        ]}

    # assign_host_check
    check_name = args.get("check_name") or ""
    if not check_name:
        return {"error": "check_name is required"}
    a = CheckAssignment(
        tenant_id=DEFAULT_TENANT_ID, check_name=check_name, scope_type="host",
        agent_id=agent.id, parameters=args.get("parameters") or {}, source="ai",
    )
    session.add(a)
    await session.commit()
    return {"assigned": check_name, "host": host, "parameters": a.parameters}
