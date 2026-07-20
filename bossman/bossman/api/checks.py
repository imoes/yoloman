"""Check library REST surface (Block G9): list the checks in checks_dir and
read one check's metadata + Starlark source. Read-only for now; assigning a
check to a host/group/OU (with per-scope thresholds) rides the existing
orchestration/GPO layer and the host page (Block G9-P2)."""

from __future__ import annotations

from typing import Any
from uuid import UUID

import nestedtext
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent, CheckAssignment
from bossman.db.session import get_session
from bossman.services import checks_library
from bossman.services.auth import Identity, user_can_manage_agent
from bossman.services.check_assignments import resolve_host_checks
from bossman.services.module_library import ModuleLibraryError

router = APIRouter()

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


@router.get("/api/v1/checks")
async def list_checks(
    settings: Settings = Depends(get_settings), _identity=Depends(get_current_identity)
) -> dict[str, Any]:
    """Every check in the library: name, short_description, source
    (translated|custom), and its options (the argspec the host-page config
    form renders)."""
    return {"checks": checks_library.list_checks(settings.checks_dir)}


@router.get("/api/v1/checks/{name}")
async def get_check(
    name: str, settings: Settings = Depends(get_settings), _identity=Depends(get_current_identity)
) -> dict[str, Any]:
    """One check's stored metadata + Starlark source."""
    try:
        return checks_library.load_check(settings.checks_dir, name)
    except ModuleLibraryError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


# ── Assignments: a check bound to a host / group / OU (Block G9-P2) ────────


def _assignment_out(a: CheckAssignment) -> dict[str, Any]:
    return {
        "id": str(a.id),
        "check_name": a.check_name,
        "scope_type": a.scope_type,
        "ou_id": str(a.ou_id) if a.ou_id else None,
        "agent_id": str(a.agent_id) if a.agent_id else None,
        "host_group_id": str(a.host_group_id) if a.host_group_id else None,
        "parameters": a.parameters or {},
        "enabled": a.enabled,
        "source": a.source,
    }


@router.get("/api/v1/agents/{agent_id}/checks")
async def effective_host_checks(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """The checks that effectively apply to this host — resolved GPO-style
    from every assignment reaching it (host + groups + OU ancestry), with
    merged params and the winning scope. Each entry is enriched with the
    check's short_description + options (the config form's argspec)."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="no such agent")
    effective = await resolve_host_checks(session, agent)
    catalog = {c["name"]: c for c in checks_library.list_checks(settings.checks_dir)}
    out = []
    for ec in effective:
        meta = catalog.get(ec.check_name, {})
        out.append({
            **ec.to_dict(),
            "short_description": meta.get("short_description", ""),
            "options": meta.get("options", {}),
            "in_library": ec.check_name in catalog,
        })
    return {"agent_id": str(agent_id), "checks": out}


@router.get("/api/v1/check-assignments")
async def list_assignments(
    agent_id: UUID | None = None,
    ou_id: UUID | None = None,
    host_group_id: UUID | None = None,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Raw check assignments, optionally filtered to one scope target — the
    direct assignments on a host / group / OU (not the resolved inheritance;
    use GET /agents/{id}/checks for the effective set)."""
    stmt = select(CheckAssignment).where(CheckAssignment.tenant_id == DEFAULT_TENANT_ID)
    if agent_id is not None:
        stmt = stmt.where(CheckAssignment.agent_id == agent_id)
    if ou_id is not None:
        stmt = stmt.where(CheckAssignment.ou_id == ou_id)
    if host_group_id is not None:
        stmt = stmt.where(CheckAssignment.host_group_id == host_group_id)
    rows = (await session.scalars(stmt.order_by(CheckAssignment.check_name))).all()
    return {"assignments": [_assignment_out(a) for a in rows]}


class CreateAssignmentRequest(BaseModel):
    check_name: str
    scope_type: str  # ou | group | host
    ou_id: UUID | None = None
    agent_id: UUID | None = None
    host_group_id: UUID | None = None
    parameters: dict[str, Any] = {}
    source: str = "manual"


@router.post("/api/v1/check-assignments")
async def create_assignment(
    body: CreateAssignmentRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity: Identity = Depends(get_current_identity),
) -> dict[str, Any]:
    """Assign a check to a host, group, or OU with per-scope parameters. A
    host-scoped assignment needs manage rights on that host; group/OU-scoped
    assignments are admin-only (they affect many hosts). The check must exist
    in the library."""
    if body.scope_type not in ("ou", "group", "host"):
        raise HTTPException(status_code=422, detail="scope_type must be one of: ou, group, host")
    scope_id = {"ou": body.ou_id, "group": body.host_group_id, "host": body.agent_id}[body.scope_type]
    if scope_id is None:
        raise HTTPException(status_code=422, detail=f"scope_type={body.scope_type} requires the matching id")
    try:
        checks_library.load_check(settings.checks_dir, body.check_name)
    except ModuleLibraryError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    # ACL: host scope → manage that host; group/OU → admin (broad blast radius).
    if body.scope_type == "host":
        if not await user_can_manage_agent(session, identity, body.agent_id):
            raise HTTPException(status_code=403, detail="not authorized to manage this host")
    else:
        if not (identity.kind == "user" and identity.role == "admin"):
            raise HTTPException(status_code=403, detail="group/OU assignments are admin-only")

    a = CheckAssignment(
        tenant_id=DEFAULT_TENANT_ID,
        check_name=body.check_name,
        scope_type=body.scope_type,
        ou_id=body.ou_id if body.scope_type == "ou" else None,
        agent_id=body.agent_id if body.scope_type == "host" else None,
        host_group_id=body.host_group_id if body.scope_type == "group" else None,
        parameters=body.parameters or {},
        source=body.source if body.source in ("manual", "autodiscovered", "ai") else "manual",
        created_by=identity.name,
    )
    session.add(a)
    await session.commit()
    return _assignment_out(a)


class UpdateAssignmentRequest(BaseModel):
    parameters: dict[str, Any]


@router.patch("/api/v1/check-assignments/{assignment_id}")
async def update_assignment(
    assignment_id: UUID,
    body: UpdateAssignmentRequest,
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> dict[str, Any]:
    """Edit an existing assignment's parameters in place (same scope/check),
    so a service check can be reconfigured without delete+recreate. Same ACL
    as delete: host scope → manage that host; group/OU → admin."""
    a = await session.get(CheckAssignment, assignment_id)
    if a is None:
        raise HTTPException(status_code=404, detail="no such assignment")
    if a.scope_type == "host":
        if not await user_can_manage_agent(session, identity, a.agent_id):
            raise HTTPException(status_code=403, detail="not authorized to manage this host")
    elif not (identity.kind == "user" and identity.role == "admin"):
        raise HTTPException(status_code=403, detail="group/OU assignments are admin-only")
    a.parameters = body.parameters or {}
    await session.commit()
    return _assignment_out(a)


@router.delete("/api/v1/check-assignments/{assignment_id}", status_code=204)
async def delete_assignment(
    assignment_id: UUID,
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> None:
    a = await session.get(CheckAssignment, assignment_id)
    if a is None:
        raise HTTPException(status_code=404, detail="no such assignment")
    if a.scope_type == "host":
        if not await user_can_manage_agent(session, identity, a.agent_id):
            raise HTTPException(status_code=403, detail="not authorized to manage this host")
    elif not (identity.kind == "user" and identity.role == "admin"):
        raise HTTPException(status_code=403, detail="group/OU assignments are admin-only")
    await session.delete(a)
    await session.commit()


# ── Auto-discovery: run checks in _discover mode on the host (Block G9-P3c) ─


async def _agent_with_address(session: AsyncSession, agent_id: UUID) -> Agent:
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="no such agent")
    if not agent.address:
        raise HTTPException(status_code=422, detail="agent has no address to reach")
    return agent


def _check_datasource(star: str) -> str:
    """Bossman-side datasource classifier — now centralised in checks_library
    (kept as a thin alias so existing call sites don't churn)."""
    return checks_library.check_datasource(star)


# Data-source markers that only exist on a Checkmk site / a Checkmk agent — a
# translated check that reads them (or fabricates a `<<<section>>>` via echo)
# can never get real data from OUR agent, so it must never be a discovery
# candidate (it would otherwise fake a placeholder item and surface everywhere).
_CHECKMK_INTERNAL_MARKERS = (
    "/var/lib/check_mk", "check_mk_agent", "/opt/checkmk", "/omd/", "agent_output",
    '["cmk"', "['cmk'", '["cmk",', "cmk -d",
)


def _is_unrunnable_source(star: str) -> bool:
    """True if the check's ONLY way to get data is a Checkmk-internal path or a
    hardcoded echo-simulated section — i.e. it can't work on our agent."""
    if any(m in star for m in _CHECKMK_INTERNAL_MARKERS):
        return True
    # `ctx.run(["echo", '... <<<section>>> ...'])` = fabricated agent output.
    if '"echo"' in star and "<<<" in star:
        return True
    return False


def _load_candidate_checks(
    settings: Settings, names: list[str] | None, datasource: str = "agent"
) -> list[dict[str, Any]]:
    """Load the checks to run discovery for, each as {name, star, sidecar,
    sidecar_format, options, short_description}.

    Checkmk-style relevance pre-filter (see cmk .../discovery/_discover/
    services.py `_find_host_plugins`): don't run every check in the library —
    only those whose DATA SOURCE the host actually has. A plain agent host
    never satisfies the 600+ SNMP checks, so running them was pure waste + the
    reason discovery surfaced far too many/irrelevant candidates. When explicit
    `names` are given (a targeted re-scan) the datasource filter is skipped."""
    from pathlib import Path

    catalog = {c["name"]: c for c in checks_library.list_checks(settings.checks_dir)}
    wanted = names if names else list(catalog)
    out: list[dict[str, Any]] = []
    for name in wanted:
        entry = catalog.get(name)
        if not entry:
            continue
        yaml_path, star_path = checks_library.check_paths(settings.checks_dir, name)
        try:
            star = star_path.read_text(encoding="utf-8")
            sidecar = Path(yaml_path).read_text(encoding="utf-8")
        except OSError:
            continue
        # Relevance pre-filter by data source (skipped for an explicit re-scan).
        if not names and _check_datasource(star) != datasource:
            continue
        # Never a candidate: reads Checkmk-site/agent internals or fakes its
        # section — no real data on our agent (drops bi_aggregation, mssql_instance,
        # lsi_array, safenet/skype `cmk`, echo-simulated lgp_info, …). Honoured
        # even for an explicit re-scan — these genuinely can't run here.
        if _is_unrunnable_source(star):
            continue
        # The sidecar is NestedText (.nt); the agent registers the tool under
        # its fqcn, so parse it out and pass it through (call_tool needs it).
        fqcn = name
        try:
            meta = nestedtext.loads(sidecar, top="dict")
            if isinstance(meta, dict) and meta.get("fqcn"):
                fqcn = str(meta["fqcn"])
        except nestedtext.NestedTextError:
            pass
        out.append({
            "name": name, "fqcn": fqcn, "star": star, "sidecar": sidecar, "sidecar_format": "nt",
            "options": entry.get("options", {}), "short_description": entry.get("short_description", ""),
        })
    return out


@router.post("/api/v1/agents/{agent_id}/discover")
async def discover_checks(
    agent_id: UUID,
    body: dict[str, Any] | None = None,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity: Identity = Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Run auto-discovery on this host: push the candidate checks and invoke
    each in _discover mode, returning the items/metrics found (Checkmk-style
    service discovery). Optional body {check_names: [...]} scopes the run
    (default: the whole library). Read-only; proposes, never assigns —
    apply the accepted proposals via POST .../discover/apply."""
    from bossman.services.agent_client import AgentClientError
    from bossman.services.discovery import run_check_discovery

    if not await user_can_manage_agent(session, identity, agent_id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
    agent = await _agent_with_address(session, agent_id)
    names = (body or {}).get("check_names")
    # A host's data source scopes discovery (agent hosts don't run SNMP checks
    # and vice-versa). Default 'agent'; SNMP devices pass datasource:'snmp'.
    datasource = (body or {}).get("datasource") or "agent"
    checks = _load_candidate_checks(settings, names, datasource)
    client = client_factory(agent, settings)
    try:
        proposals = await run_check_discovery(client, checks)
    except AgentClientError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"agent_id": str(agent_id), "candidates": len(checks), "proposals": [p.to_dict() for p in proposals]}


@router.post("/api/v1/agents/{agent_id}/discover/apply")
async def apply_discovery(
    agent_id: UUID,
    body: dict[str, Any],
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> dict[str, Any]:
    """Turn accepted discovery proposals into host-scoped check assignments.
    body {assign: [{check_name, item?, parameters?}, ...]}. The `item` (if any)
    is folded into the assignment's parameters as `item` so the check runs for
    that discovered item."""
    if not await user_can_manage_agent(session, identity, agent_id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="no such agent")
    created = []
    for spec in body.get("assign", []):
        check_name = spec.get("check_name")
        if not check_name:
            continue
        params = dict(spec.get("parameters") or {})
        if spec.get("item"):
            params["item"] = spec["item"]
        a = CheckAssignment(
            tenant_id=DEFAULT_TENANT_ID, check_name=check_name, scope_type="host",
            agent_id=agent_id, parameters=params, source="autodiscovered", created_by=identity.name,
        )
        session.add(a)
        created.append(check_name)
    await session.commit()
    return {"agent_id": str(agent_id), "assigned": created}


# ── Credential provisioning (Block G9-P3d) ─────────────────────────────────


@router.get("/api/v1/checks/{name}/provisioning")
async def check_provisioning(
    name: str, settings: Settings = Depends(get_settings), _identity=Depends(get_current_identity)
) -> dict[str, Any]:
    """Whether this check ships a provisioning recipe (create a monitoring
    account) and, if so, the admin params the wizard must collect."""
    from bossman.services import provisioning

    recipe = provisioning.load_recipe(settings.checks_dir, name)
    if recipe is None:
        return {"available": False}
    return {
        "available": True,
        "title": recipe.get("title", "Provision " + name),
        "description": recipe.get("description", ""),
        "admin_params": provisioning.admin_param_specs(recipe),
    }


@router.post("/api/v1/agents/{agent_id}/checks/{name}/provision")
async def provision_check(
    agent_id: UUID,
    name: str,
    body: dict[str, Any],
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity: Identity = Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Run the check's provisioning recipe on the host (create the monitoring
    account with the operator-supplied admin creds), then assign the check to
    the host with the generated monitoring credential. Admin creds are used
    only for the setup command and never stored. Needs manage rights on the
    host. body: {admin_params: {...}, extra_params?: {...}}."""
    from bossman.services import provisioning

    if not await user_can_manage_agent(session, identity, agent_id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
    recipe = provisioning.load_recipe(settings.checks_dir, name)
    if recipe is None:
        raise HTTPException(status_code=404, detail=f"check {name!r} has no provisioning recipe")
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    result = await provisioning.provision(client, recipe, body.get("admin_params") or {})
    if not result["ok"]:
        raise HTTPException(status_code=422, detail=result["error"])

    params = {**(body.get("extra_params") or {}), **result["produced_params"]}
    a = CheckAssignment(
        tenant_id=DEFAULT_TENANT_ID, check_name=name, scope_type="host",
        agent_id=agent_id, parameters=params, source="autodiscovered", created_by=identity.name,
    )
    session.add(a)
    await session.commit()
    # never echo the admin creds; the produced monitoring cred is what was stored
    return {"assignment": _assignment_out(a), "provisioned": True}
