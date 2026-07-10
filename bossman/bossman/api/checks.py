"""Check library REST surface (Block G9): list the checks in checks_dir and
read one check's metadata + Starlark source. Read-only for now; assigning a
check to a host/group/OU (with per-scope thresholds) rides the existing
orchestration/GPO layer and the host page (Block G9-P2)."""

from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
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
