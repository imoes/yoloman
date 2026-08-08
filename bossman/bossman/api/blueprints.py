"""Blueprint management — CRUD over blueprints + compile-to-playbook + seed
sample drafts. See services/blueprint.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.models import DEFAULT_TENANT_ID, Blueprint
from bossman.db.session import get_session
from bossman.services.blueprint import compile_blueprint, seed_blueprint_drafts

router = APIRouter()


class BlueprintIn(BaseModel):
    name: str
    description: str = ""
    status: str = "draft"
    services: list = []


class BlueprintOut(BaseModel):
    id: UUID
    name: str
    description: str
    status: str
    services: list
    created_at: datetime
    updated_at: datetime

    @classmethod
    def of(cls, b: Blueprint) -> "BlueprintOut":
        return cls(id=b.id, name=b.name, description=b.description, status=b.status,
                   services=b.services or [], created_at=b.created_at, updated_at=b.updated_at)


@router.get("/api/v1/blueprints", response_model=list[BlueprintOut])
async def list_blueprints(session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    rows = (await session.scalars(select(Blueprint).order_by(Blueprint.name))).all()
    return [BlueprintOut.of(b) for b in rows]


@router.get("/api/v1/blueprints/{bp_id}", response_model=BlueprintOut)
async def get_blueprint(bp_id: UUID, session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    b = await session.get(Blueprint, bp_id)
    if b is None:
        raise HTTPException(404, "no such blueprint")
    return BlueprintOut.of(b)


@router.post("/api/v1/blueprints", response_model=BlueprintOut)
async def create_blueprint(body: BlueprintIn, session: AsyncSession = Depends(get_session),
                           identity: Identity = Depends(get_current_identity)):
    b = Blueprint(tenant_id=DEFAULT_TENANT_ID, name=body.name, description=body.description,
                  status=body.status, services=body.services or [], created_by=identity.name)
    session.add(b)
    await session.commit()
    await session.refresh(b)
    return BlueprintOut.of(b)


@router.put("/api/v1/blueprints/{bp_id}", response_model=BlueprintOut)
async def update_blueprint(bp_id: UUID, body: BlueprintIn, session: AsyncSession = Depends(get_session),
                           _i: Identity = Depends(get_current_identity)):
    b = await session.get(Blueprint, bp_id)
    if b is None:
        raise HTTPException(404, "no such blueprint")
    b.name, b.description, b.status, b.services = body.name, body.description, body.status, body.services or []
    b.updated_at = datetime.now(b.updated_at.tzinfo) if b.updated_at else datetime.utcnow()
    await session.commit()
    return BlueprintOut.of(b)


@router.delete("/api/v1/blueprints/{bp_id}", status_code=204)
async def delete_blueprint(bp_id: UUID, session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    b = await session.get(Blueprint, bp_id)
    if b is not None:
        await session.delete(b)
        await session.commit()


@router.get("/api/v1/blueprints/{bp_id}/compile")
async def compile_blueprint_route(bp_id: UUID, session: AsyncSession = Depends(get_session),
                                  settings: Settings = Depends(get_settings), _i: Identity = Depends(get_current_identity)):
    """Compile the blueprint into a typed playbook + wiring/order report."""
    b = await session.get(Blueprint, bp_id)
    if b is None:
        raise HTTPException(404, "no such blueprint")
    return compile_blueprint(settings, b)


@router.post("/api/v1/blueprints/{bp_id}/save-as-runbook")
async def save_blueprint_as_runbook(bp_id: UUID, session: AsyncSession = Depends(get_session),
                                    settings: Settings = Depends(get_settings), identity: Identity = Depends(get_current_identity)):
    """Compile the blueprint and persist the typed playbook as a Runbook, so the
    stack can be run (run-runbook), bound to a scope (orchestration link), or
    delivered as a PXE target_runbook at boot. Idempotent on the runbook name."""
    from bossman.db.models import Runbook

    b = await session.get(Blueprint, bp_id)
    if b is None:
        raise HTTPException(404, "no such blueprint")
    result = compile_blueprint(settings, b)
    doc = result["playbook"]
    name = doc["name"]
    rb = await session.scalar(select(Runbook).where(Runbook.name == name))
    if rb is None:
        rb = Runbook(tenant_id=DEFAULT_TENANT_ID, name=name, kind="runbook", folder="blueprints",
                     doc=doc, created_by=identity.name)
        session.add(rb)
    else:
        rb.doc = doc
    b.status = "ready"
    await session.commit()
    return {"runbook": name, "steps": len(doc["steps"]), "unresolved": result["unresolved"]}


@router.post("/api/v1/blueprints/seed-drafts")
async def seed_drafts(session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    """Install the sample blueprint drafts (idempotent)."""
    added = await seed_blueprint_drafts(session)
    await session.commit()
    return {"added": added}
