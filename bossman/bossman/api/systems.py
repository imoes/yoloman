"""Systems API (test-systems Block 1, read-only half) — propose a `System` (the
unit above a host: apps + wiring) from a seed host's live state. Persistence
(System/SystemMember tables + POST/GET by id) is a follow-up slice once the
shape is validated. See docs/test-systems.md."""
from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity, require_manage_agent
from bossman.api.management import _agent_with_address
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import System, SystemMember
from bossman.db.session import get_session
from bossman.services import system_clone, system_discover, system_promote, system_rehearsal

router = APIRouter()

_CORE_MEMBER_KEYS = {"target", "app", "role_in_system"}


class SystemCreate(BaseModel):
    name: str
    description: str | None = None
    seed_agent_id: UUID | None = None
    members: list[dict[str, Any]] = []      # proposed members (target/app/role + tier fields)
    edges: list[dict[str, Any]] = []


class CloneBody(BaseModel):
    target_agent_id: UUID          # where the sandbox runs
    dry_run: bool = True


class RehearseBody(BaseModel):
    target_agent_id: UUID              # where the sandbox runs
    image_overrides: dict[str, str] = {}   # {member_app: new_image} = the change under test
    teardown: bool = True


class PromoteBody(BaseModel):
    target_agent_id: UUID                  # the PROD host
    image_overrides: dict[str, str] = {}   # {member_app: new_image} = the change
    rehearse_first: bool = True            # safety gate: only promote on a green rehearsal
    dry_run: bool = False


def _member_dict(m: SystemMember) -> dict[str, Any]:
    return {"id": str(m.id), "target": m.target, "app": m.app,
            "role_in_system": m.role_in_system, "config": m.config or {}}


def _system_dict(s: System, *, full: bool = True) -> dict[str, Any]:
    out: dict[str, Any] = {
        "id": str(s.id), "name": s.name, "description": s.description,
        "seed_agent_id": str(s.seed_agent_id) if s.seed_agent_id else None,
        "edges": s.edges or [], "member_count": len(s.members),
        "created_at": s.created_at.isoformat() if s.created_at else None,
    }
    if full:
        out["members"] = [_member_dict(m) for m in s.members]
    return out


@router.get("/api/v1/systems/propose")
async def propose_system(
    agent_id: UUID = Query(..., description="seed host to propose a System from"),
    name: str | None = Query(None),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_agent), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Propose (not persist) a System from a seed host: its apps across docker /
    k8s / native + compose-derived wiring. The read-only foundation for
    clone-a-prod-system."""
    agent = await _agent_with_address(session, agent_id)
    return await system_discover.propose_system(session, agent, client_factory, settings, name=name)


@router.post("/api/v1/systems")
async def create_system(
    body: SystemCreate,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Persist a System (typically a confirmed+named proposal). Each member's
    non-core fields (image/chart/compose_file/…) are stored in its config blob."""
    exists = (await session.scalars(select(System).where(System.name == body.name))).first()
    if exists is not None:
        raise HTTPException(status_code=409, detail=f"a system named {body.name!r} already exists")
    sys_row = System(
        name=body.name, description=body.description, seed_agent_id=body.seed_agent_id,
        edges=body.edges or [], created_by=getattr(identity, "name", None),
    )
    for m in body.members:
        config = {k: v for k, v in m.items() if k not in _CORE_MEMBER_KEYS and k != "id" and v is not None}
        sys_row.members.append(SystemMember(
            target=str(m.get("target") or "native"), app=str(m.get("app") or ""),
            role_in_system=m.get("role_in_system"), config=config,
        ))
    session.add(sys_row)
    await session.commit()
    await session.refresh(sys_row)
    return _system_dict(sys_row)


@router.get("/api/v1/systems")
async def list_systems(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Systems — the unit above a host: applications plus the wiring between them.

    **Read-only for now, and proposed rather than stored**: a system is derived from a seed host's
    live state so its shape can be validated before persistence exists. So this listing describes
    what *would* be a system, which is why nothing here creates one.
    """
    rows = (await session.scalars(select(System).order_by(System.created_at.desc()))).all()
    return {"systems": [_system_dict(s, full=False) for s in rows], "count": len(rows)}


@router.get("/api/v1/systems/{system_id}")
async def get_system(
    system_id: UUID,
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """One proposed system: its members and how they were inferred from the seed host's live state.
    404 when there is no such id."""
    s = await session.get(System, system_id)
    if s is None:
        raise HTTPException(status_code=404, detail="no such system")
    return _system_dict(s)


@router.post("/api/v1/systems/{system_id}/clone")
async def clone_system_route(
    system_id: UUID, body: CloneBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Clone the System's seed host into a sandbox on the target (cross-tier:
    docker names prefixed, host ports dropped). Dry-run by default — preview the
    config plan + docker run commands before any write. The base of the rehearsal
    plane."""
    s = await session.get(System, system_id)
    if s is None:
        raise HTTPException(status_code=404, detail="no such system")
    target = await _agent_with_address(session, body.target_agent_id)
    return await system_clone.clone_system(session, s, target, client_factory, settings, dry_run=body.dry_run)


@router.post("/api/v1/systems/{system_id}/rehearse")
async def rehearse_system_route(
    system_id: UUID, body: RehearseBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Rehearse the System in a sandbox on the target: bring its docker members up
    for real (optionally with image overrides = the change under test), health-gate
    them, then tear down. Returns pass/fail — the behavioral test before prod."""
    s = await session.get(System, system_id)
    if s is None:
        raise HTTPException(status_code=404, detail="no such system")
    target = await _agent_with_address(session, body.target_agent_id)
    return await system_rehearsal.rehearse(
        s, target, client_factory, settings,
        image_overrides=body.image_overrides, teardown=body.teardown,
    )


@router.post("/api/v1/systems/{system_id}/promote")
async def promote_system_route(
    system_id: UUID, body: PromoteBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Promote a rehearsed change to prod as one atomic change-set (rolls the whole
    set back if any member fails). Gated on a green rehearsal unless disabled."""
    s = await session.get(System, system_id)
    if s is None:
        raise HTTPException(status_code=404, detail="no such system")
    target = await _agent_with_address(session, body.target_agent_id)
    return await system_promote.promote(
        s, target, body.image_overrides, client_factory, settings,
        rehearse_first=body.rehearse_first, dry_run=body.dry_run,
    )


@router.delete("/api/v1/systems/{system_id}")
async def delete_system(
    system_id: UUID,
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Discard a proposed system. Nothing on any host is affected — a proposal is a description,
    and deleting it deletes the description."""
    s = await session.get(System, system_id)
    if s is None:
        raise HTTPException(status_code=404, detail="no such system")
    await session.delete(s)   # members cascade
    await session.commit()
    return {"deleted": str(system_id)}
