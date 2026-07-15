"""Block J4 — Cockpit-artige Host-Verwaltung: live pass-through reads (and a
few actions) for the per-host management page (Services / Logs / Accounts /
Storage / Network).

Like api/processes.py these are *live* pulls proxied to one agent, never
Bossman's aggregated Postgres data. Every read is a read-only agent *module*
(service_facts / journal / getent / storage_facts / …), so it goes through the
same `call_tool` path the plan engine uses (POST /api/v1/tools/{name}). Write
actions live next to service_control in api/agents.py; this router is mostly
reads plus the aggregate helpers the UI needs.

The agent's write gate is the only access control on mutating tools: a
read-only agent returns 403, surfaced here as a 502 with the agent's message.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity, require_manage_agent
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import DEFAULT_TENANT_ID, Agent, HostConfigResource
from bossman.db.session import get_session
from bossman.services.agent_client import AgentClientError
from bossman.services.cve_collect import collect_host

router = APIRouter()


async def _agent_with_address(session: AsyncSession, agent_id: UUID) -> Agent:
    """Resolve an agent that can be reached directly, or raise the same
    404/422 an on-demand read uses (mirrors api/processes.py)."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")
    if not agent.address:
        raise HTTPException(status_code=422, detail=f"agent {agent.name!r} has no reachable address")
    return agent


# ---- Generic tool router (the REST counterpart to Bossman's MCP router) ----
#
# Bossman's MCP server acts as a gateway: an MCP client sees the fleet of
# managed agents and each agent's tools, and routes calls through Bossman to
# the agent. These two routes are the REST equivalent the UI (and any HTTP
# client) uses; the MCP tools list_agent_tools / call_agent_tool in
# bossman/mcp/server.py are thin wrappers over exactly this proxy.


class ToolCallRequest(BaseModel):
    # The tool's own params; dry_run is honored by write modules themselves.
    params: dict[str, Any] = {}


@router.get("/api/v1/agents/{agent_id}/tools")
async def list_agent_tools_route(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Every tool one managed agent currently exposes ([{name, kind, writes}]),
    proxied from the agent's own GET /api/v1/tools. Write tools appear only
    when that agent's write gate is open."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        tools = await client.list_tools()
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "tools": tools}


@router.post("/api/v1/agents/{agent_id}/tools/{tool_name}")
async def call_agent_tool_route(
    agent_id: UUID,
    tool_name: str,
    body: ToolCallRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Route a single tool call to one managed agent (proxies the agent's
    POST /api/v1/tools/{name}). The agent's write gate + ACL + audit are the
    enforcement point; a read-only agent rejecting a write tool surfaces as a
    502 with the agent's message."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool(tool_name, body.params)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "tool": tool_name, "result": result}


@router.get("/api/v1/agents/{agent_id}/state/observed")
async def get_agent_state_observed(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """The host as one JSON document (Block F1, the server-as-a-document read):
    proxies the agent's GET /api/v1/state/observed — discovered services + each
    config file read back structured via its codec (or a sha256 ref). Live
    pass-through, never Bossman's Postgres."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        observed = await client.state_observed()
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "observed": observed}


@router.get("/api/v1/agents/{agent_id}/state/generations")
async def get_agent_state_generations(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """The agent's local desired-state generation history (plan/apply/rollback
    store), proxied from GET /api/v1/state/generations. Distinct from Bossman's
    own compiled-desired-state generations (CompiledHostState) — this is what
    the host itself has applied and can roll back to."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        gens = await client.state_generations()
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), **(gens if isinstance(gens, dict) else {"generations": gens})}


class StateDocument(BaseModel):
    # One config resource per edited file: {type: "config", path, format,
    # separator?, values}. A value of null deletes that key (codec-level).
    resources: list[dict[str, Any]] = []


class StateApplyRequest(StateDocument):
    dry_run: bool = True


@router.post("/api/v1/agents/{agent_id}/state/plan")
async def post_agent_state_plan(
    agent_id: UUID,
    body: StateDocument,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Diff a desired config Document against the host (Block K1), proxying the
    agent's POST /api/v1/state/plan — the per-key preview behind the value
    editor. Read-only; writes nothing."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        plan = await client.state_plan({"resources": body.resources})
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), **(plan if isinstance(plan, dict) else {"plan": plan})}


@router.post("/api/v1/agents/{agent_id}/state/apply")
async def post_agent_state_apply(
    agent_id: UUID,
    body: StateApplyRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Converge a desired config Document on the host (Block K1), proxying the
    agent's POST /api/v1/state/apply. dry_run previews (the plan) without
    writing; a real apply writes through the codec merge and records a
    generation (so every edit is versioned + roll-backable). A read-only agent
    rejects the write → surfaced as 502."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        result = await client.state_apply({"resources": body.resources}, body.dry_run)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    # K3: on a real apply, record the desired resources in Bossman's DB (the
    # fleet-side key-value database) so drift = desired-vs-observed and the
    # values can later be scoped to an OU (K4). One row per (agent, path).
    if not body.dry_run:
        for r in body.resources:
            path = r.get("path")
            if not path:
                continue
            existing = await session.scalar(
                select(HostConfigResource).where(
                    HostConfigResource.agent_id == agent.id, HostConfigResource.path == path
                )
            )
            if existing is None:
                existing = HostConfigResource(tenant_id=UUID(DEFAULT_TENANT_ID), agent_id=agent.id, path=path)
                session.add(existing)
            existing.type = r.get("type", "config")
            existing.config_format = r.get("format")
            existing.separator = r.get("separator")
            existing.values = r.get("values", {})
            existing.template = r.get("template")
            existing.updated_at = datetime.now(timezone.utc)
        await session.commit()
    return {"agent_id": str(agent.id), **(result if isinstance(result, dict) else {"result": result})}


@router.get("/api/v1/agents/{agent_id}/config-drift")
async def get_agent_config_drift(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Drift for this host (Block K3): re-plan every desired config resource
    Bossman has recorded against the host's live state. A resource whose plan
    action isn't 'noop' has drifted (someone/something changed the file out of
    band). Returns the managed paths + the drifted ones with their per-key
    changes — the same plan shape the value editor's preview uses."""
    agent = await _agent_with_address(session, agent_id)
    rows = (
        await session.scalars(select(HostConfigResource).where(HostConfigResource.agent_id == agent.id))
    ).all()
    if not rows:
        return {"agent_id": str(agent.id), "managed": [], "drift": []}
    resources = []
    for row in rows:
        res: dict[str, Any] = {"type": row.type, "path": row.path, "values": row.values or {}}
        if row.config_format:
            res["format"] = row.config_format
        if row.separator:
            res["separator"] = row.separator
        if row.template:
            res["template"] = row.template
        resources.append(res)
    client = client_factory(agent, settings)
    try:
        plan = await client.state_plan({"resources": resources})
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    changes = plan.get("changes", []) if isinstance(plan, dict) else []
    drift = [c for c in changes if c.get("action") not in (None, "noop") or c.get("error")]
    return {
        "agent_id": str(agent.id),
        "managed": [row.path for row in rows],
        "drift": drift,
    }


def _row_to_resource(row: HostConfigResource) -> dict[str, Any]:
    res: dict[str, Any] = {"type": row.type, "path": row.path, "values": row.values or {}}
    if row.config_format:
        res["format"] = row.config_format
    if row.separator:
        res["separator"] = row.separator
    if row.template:
        res["template"] = row.template
    return res


@router.post("/api/v1/agents/{agent_id}/config/reapply")
async def post_agent_config_reapply(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Re-sync the host to its recorded desired config (Block K3): re-apply
    every stored resource through the document loop, converging any drift back
    and recording a generation. The desired values win over out-of-band edits."""
    agent = await _agent_with_address(session, agent_id)
    rows = (
        await session.scalars(select(HostConfigResource).where(HostConfigResource.agent_id == agent.id))
    ).all()
    if not rows:
        raise HTTPException(status_code=404, detail="no desired config recorded for this host")
    client = client_factory(agent, settings)
    try:
        result = await client.state_apply({"resources": [_row_to_resource(r) for r in rows]}, False)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), **(result if isinstance(result, dict) else {"result": result})}


class StateRollbackRequest(BaseModel):
    generation: int
    dry_run: bool = True


@router.post("/api/v1/agents/{agent_id}/state/rollback")
async def post_agent_state_rollback(
    agent_id: UUID,
    body: StateRollbackRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Roll the host's config back to a past generation (Block F2), proxying
    the agent's POST /api/v1/state/rollback. dry_run (default) returns the plan
    — the observed→target diff — without writing; a real rollback needs the
    agent's write gate open, which a read-only agent rejects (surfaced as 502)."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        result = await client.state_rollback(body.generation, body.dry_run)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), **(result if isinstance(result, dict) else {"result": result})}


@router.get("/api/v1/agents/{agent_id}/service-units")
async def get_agent_services(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Block J4a — the host's systemd service units + their load/active/sub
    state, via the read-only `service_facts` module. The UI drives its
    per-unit start/stop/restart/enable/disable off this list (each action
    goes to POST /agents/{id}/service-control).

    Path is /service-units, not /services: the latter is the monitoring
    read route (GET /agents/{id}/services -> list[ServiceOut] of graded
    check states) and the two must not collide on the router."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool("service_facts", {})
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    # call_tool returns the agent's tool envelope {changed, msg, data}; the
    # unit list is under data. Pass it through in a stable shape for the UI.
    services = (result or {}).get("data") if isinstance(result, dict) else None
    return {"agent_id": str(agent.id), "services": services or []}


@router.get("/api/v1/agents/{agent_id}/logs")
async def get_agent_logs(
    agent_id: UUID,
    lines: int = Query(200, ge=1, le=5000, description="Most recent N journal entries"),
    unit: str | None = Query(None, description="Restrict to one systemd unit"),
    priority: str | None = Query(None, description="Syslog priority (0-7 or a name like 'err')"),
    since: str | None = Query(None, description="journalctl time spec, e.g. '-1h' or 'yesterday'"),
    grep: str | None = Query(None, description="MESSAGE regex"),
    boot: bool = Query(False, description="Current boot only"),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Block J4b — the host's journald log, via the read-only `journal`
    module (`journalctl -o json`). Filters map 1:1 to the module's params."""
    agent = await _agent_with_address(session, agent_id)
    params: dict[str, Any] = {"lines": lines, "boot": boot}
    if unit:
        params["unit"] = unit
    if priority:
        params["priority"] = priority
    if since:
        params["since"] = since
    if grep:
        params["grep"] = grep
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool("journal", params)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    data = (result or {}).get("data") if isinstance(result, dict) else None
    data = data or {}
    return {"agent_id": str(agent.id), "entries": data.get("entries") or [], "count": data.get("count") or 0}


# ---- /var/log file logs (read-only, path-jailed logfiles module) ----------


@router.get("/api/v1/agents/{agent_id}/logs/files")
async def list_agent_log_files(
    agent_id: UUID,
    extra_paths: list[str] | None = Query(None, description="Extra custom log files/dirs to include"),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Enumerate the host's plain-text log files under /var/log (+ any custom
    paths) via the read-only, path-jailed `logfiles` module."""
    agent = await _agent_with_address(session, agent_id)
    params: dict[str, Any] = {"state": "list"}
    if extra_paths:
        params["extra_paths"] = extra_paths
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool("logfiles", params)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    data = _tool_data(result)
    return {"agent_id": str(agent.id), "roots": data.get("roots", []), "files": data.get("files", [])}


@router.get("/api/v1/agents/{agent_id}/logs/file")
async def read_agent_log_file(
    agent_id: UUID,
    path: str = Query(..., description="Log file path (must resolve within an allowed root)"),
    lines: int = Query(500, ge=1, le=5000),
    grep: str | None = Query(None),
    regex: bool = Query(False, description="Treat grep as an extended regex (grep -E)"),
    invert: bool = Query(False, description="Keep lines that do NOT match grep (grep -v)"),
    extra_paths: list[str] | None = Query(None),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Tail one log file (last N lines, optional grep) via `logfiles`. `grep`
    is a plain substring, an extended regex when regex=true (grep -E), and
    inverted when invert=true (grep -v). The module rejects any path outside
    /var/log + the configured custom roots."""
    agent = await _agent_with_address(session, agent_id)
    params: dict[str, Any] = {"state": "read", "path": path, "lines": lines}
    if grep:
        params["grep"] = grep
        if regex:
            params["regex"] = True
        if invert:
            params["invert"] = True
    if extra_paths:
        params["extra_paths"] = extra_paths
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool("logfiles", params)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    data = _tool_data(result)
    return {
        "agent_id": str(agent.id),
        "path": data.get("path", path),
        "lines": data.get("lines", []),
        "truncated": data.get("truncated", False),
        "size": data.get("size", 0),
    }


# ---- J4c: accounts (users + groups) ---------------------------------------


def _getent_rows(result: Any) -> list[list[str]]:
    """Pull the raw colon-split field lists out of a getent tool envelope
    ({changed, data:[{name, fields:[...]}]})."""
    data = (result or {}).get("data") if isinstance(result, dict) else None
    rows: list[list[str]] = []
    for entry in data or []:
        fields = entry.get("fields") if isinstance(entry, dict) else None
        if isinstance(fields, list):
            rows.append([str(f) for f in fields])
    return rows


@router.get("/api/v1/agents/{agent_id}/accounts")
async def get_agent_accounts(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Block J4c — the host's users and groups, via the read-only `getent`
    module (passwd + group databases), parsed into a friendly shape. Each
    user carries `system` (uid < 1000) so the UI can separate human accounts
    from service accounts (shadow is not read — it needs root and isn't shown)."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        passwd = await client.call_tool("getent", {"database": "passwd"})
        group = await client.call_tool("getent", {"database": "group"})
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    users = []
    for f in _getent_rows(passwd):
        # name:x:uid:gid:gecos:home:shell
        if len(f) < 7:
            continue
        try:
            uid = int(f[2])
        except ValueError:
            continue
        users.append({"name": f[0], "uid": uid, "gid": int(f[3]) if f[3].isdigit() else None,
                      "gecos": f[4], "home": f[5], "shell": f[6], "system": uid < 1000})
    groups = []
    for f in _getent_rows(group):
        # name:x:gid:members
        if len(f) < 3:
            continue
        gid = int(f[2]) if f[2].isdigit() else None
        members = [m for m in (f[3].split(",") if len(f) > 3 and f[3] else []) if m]
        groups.append({"name": f[0], "gid": gid, "members": members, "system": gid is not None and gid < 1000})

    return {"agent_id": str(agent.id), "users": users, "groups": groups}


class UserActionRequest(BaseModel):
    name: str
    state: str = "present"  # present | absent
    uid: str | None = None
    group: str | None = None
    groups: str | None = None
    shell: str | None = None
    home: str | None = None
    comment: str | None = None
    system: bool | None = None
    create_home: bool | None = None
    remove: bool | None = None
    dry_run: bool = False


class GroupActionRequest(BaseModel):
    name: str
    state: str = "present"  # present | absent
    gid: str | None = None
    system: bool | None = None
    dry_run: bool = False


def _clean_params(model: BaseModel) -> dict[str, Any]:
    """Forward only the fields the caller actually set (drop Nones), so the
    agent module applies its own defaults for the rest."""
    return {k: v for k, v in model.model_dump().items() if v is not None}


@router.post("/api/v1/agents/{agent_id}/accounts/user")
async def manage_agent_user(
    agent_id: UUID,
    body: UserActionRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Block J4c — create/modify/remove a user via the write-gated `user`
    module. dry_run is honored by the module (check_mode)."""
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name must not be empty")
    if body.state not in ("present", "absent"):
        raise HTTPException(status_code=422, detail="state must be present or absent")
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool("user", _clean_params(body))
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "result": result}


@router.post("/api/v1/agents/{agent_id}/accounts/group")
async def manage_agent_group(
    agent_id: UUID,
    body: GroupActionRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Block J4c — create/remove a group via the write-gated `group` module."""
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name must not be empty")
    if body.state not in ("present", "absent"):
        raise HTTPException(status_code=422, detail="state must be present or absent")
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool("group", _clean_params(body))
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "result": result}


# ---- J4d: storage overview (LVM/VDO/block via storage_facts; ZFS via zpool) --


def _tool_data(result: Any) -> dict:
    d = (result or {}).get("data") if isinstance(result, dict) else None
    return d if isinstance(d, dict) else {}


@router.get("/api/v1/agents/{agent_id}/storage")
async def get_agent_storage(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Block J4d — a read-only storage overview: block devices + LVM + VDO via
    the native storage_facts module, plus ZFS pools via the baked zpool_facts
    module. ZFS is fetched separately and degrades on its own (a host without
    zfs makes zpool_facts fail — reported as {available: false}, not a 502).
    Write actions (create/remove VG/LV/filesystem/VDO/ZFS) go through the
    generic tool router POST /agents/{id}/tools/{fqcn}."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        facts = await client.call_tool("storage_facts", {})
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    data = _tool_data(facts)

    # ZFS overview from the baked zpool_facts module; tolerate its absence.
    zfs: dict[str, Any] = {"available": False}
    try:
        pools = await client.call_tool("community.general.zpool_facts", {})
        zfs = {"available": True, "pools": _tool_data(pools).get("pools", [])}
    except AgentClientError as exc:
        zfs["error"] = str(exc)

    return {
        "agent_id": str(agent.id),
        "block_devices": data.get("block_devices", {}),
        "lvm": data.get("lvm", {}),
        "vdo": data.get("vdo", {}),
        "zfs": zfs,
    }


# ---- J4e: network (baked yoloman.network_interface) -----------------------


class NetworkConfigRequest(BaseModel):
    name: str
    state: str = "present"  # present | absent
    method: str | None = None  # dhcp | static | manual
    address: str | None = None
    gateway: str | None = None
    dns: list[str] | None = None
    mtu: int | None = None
    mac: str | None = None
    provider: str | None = None  # networkmanager | netplan | networkd | ifupdown (auto if None)
    dry_run: bool = False


@router.get("/api/v1/agents/{agent_id}/network")
async def get_agent_network(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Block J4e — the host's current network config (interfaces/addresses/
    routes/DNS) via the baked yoloman.network_interface module in gathered
    mode (parses `ip` output; read-only)."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool("yoloman.network_interface", {"state": "gathered"})
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    data = _tool_data(result)
    return {
        "agent_id": str(agent.id),
        "provider": data.get("provider", "unknown"),
        "interfaces": data.get("interfaces", []),
        "routes": data.get("routes", []),
        "dns": data.get("dns", {}),
    }


@router.post("/api/v1/agents/{agent_id}/network")
async def configure_agent_network(
    agent_id: UUID,
    body: NetworkConfigRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Block J4e — configure or remove an interface via the write-gated baked
    yoloman.network_interface module. The module auto-detects the host's
    network provider (NetworkManager / netplan / systemd-networkd / ifupdown),
    or the caller may force one via `provider`. dry_run is honored by the
    module (check_mode); a host with no supported provider fails cleanly (502)."""
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name must not be empty")
    if body.state not in ("present", "absent"):
        raise HTTPException(status_code=422, detail="state must be present or absent")
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    params = {k: v for k, v in body.model_dump().items() if v is not None}
    try:
        result = await client.call_tool("yoloman.network_interface", params)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "result": result}


# ---- Software updates (baked yoloman.package_updates) ---------------------


class UpdatesApplyRequest(BaseModel):
    security_only: bool = False
    dry_run: bool = False


@router.get("/api/v1/agents/{agent_id}/updates")
async def get_agent_updates(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Cockpit "Software updates" — pending OS package updates via the baked
    yoloman.package_updates module (apt / dnf / yum, auto-detected). Refreshes
    the package index (apt update / dnf metadata), so it mutates the cache but
    not the system; read-only w.r.t. installed packages."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool("yoloman.package_updates", {"state": "list"})
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    data = _tool_data(result)
    return {
        "agent_id": str(agent.id),
        "manager": data.get("manager", "unknown"),
        "updates": data.get("updates", []),
        "count": data.get("count", 0),
        "security_count": data.get("security_count", -1),
        "reboot_required": data.get("reboot_required", False),
    }


@router.post("/api/v1/agents/{agent_id}/updates")
async def apply_agent_updates(
    agent_id: UUID,
    body: UpdatesApplyRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Cockpit "Apply (security) updates" — installs pending updates via the
    write-gated yoloman.package_updates module. dry_run is honored (check_mode);
    security_only installs only security updates (apt: unattended-upgrade;
    dnf: --security)."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    params = {"state": "apply", "security_only": body.security_only, "dry_run": body.dry_run}
    try:
        result = await client.call_tool("yoloman.package_updates", params)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "result": result}


# ---- CVEs fixed by pending updates (Block 4-C) ----------------------------


@router.get("/api/v1/agents/{agent_id}/cves")
async def get_agent_cves(
    agent_id: UUID,
    request: Request,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """CVEs that this host's pending upgrades would fix — correlated live and
    persisted (so the fleet Security page has fresh data for viewed hosts)."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    feed = request.app.state.cve_feed
    try:
        rows = await collect_host(session, agent, client, feed)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent.id), "count": len(rows), "cves": rows}


# ---- Virtualization (virt_facts detect/list; qm/virsh control) ------------


@router.get("/api/v1/agents/{agent_id}/virt")
async def get_agent_virt(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Local virtualization overview: which hypervisor stack(s) this host runs
    (Proxmox qm/pct, libvirt virsh) and their guests, via the read-only
    virt_facts module. Guest control goes through the generic tool router
    POST /agents/{id}/tools/{qm|virsh}."""
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    try:
        result = await client.call_tool("virt_facts", {})
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    data = _tool_data(result)
    return {
        "agent_id": str(agent.id),
        "hypervisors": data.get("hypervisors", []),
        "proxmox": data.get("proxmox", {"available": False}),
        "libvirt": data.get("libvirt", {"available": False}),
    }
