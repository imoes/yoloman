"""Site CRUD + subnets — the AD Sites-and-Services object. A Site is a policy
scope defined by SUBNETS (CIDRs), not explicit membership: a host belongs to a
site when its primary IP falls inside one of the site's subnets (see
compiler.resolve_site_ids). Like a HostGroup a site lives inside an OU (ou_id)
for tree placement; GPO precedence is global < group < OU < Site < host.
"""

from __future__ import annotations

import ipaddress
from datetime import datetime
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import OUNode, Site
from bossman.db.session import get_session

router = APIRouter()

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


class SiteIn(BaseModel):
    name: str
    description: str = ""
    ou_id: UUID | None = None
    subnets: list[str] = []


class SiteOut(BaseModel):
    id: UUID
    name: str
    description: str
    ou_id: UUID | None
    subnets: list[str]
    created_at: datetime


def _validate_cidrs(cidrs: list[str]) -> list[str]:
    """Normalize + validate CIDRs; 422 on a bad one. Blanks dropped, dupes kept
    stable-ordered (the operator's order is meaningful for display)."""
    out: list[str] = []
    for raw in cidrs or []:
        c = (raw or "").strip()
        if not c:
            continue
        try:
            ipaddress.ip_network(c, strict=False)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=f"invalid subnet {c!r}") from exc
        if c not in out:
            out.append(c)
    return out


def _to_out(site: Site) -> SiteOut:
    return SiteOut(
        id=site.id, name=site.name, description=site.description, ou_id=site.ou_id,
        subnets=list(site.subnets or []), created_at=site.created_at,
    )


async def _get_site_or_404(session: AsyncSession, site_id: UUID) -> Site:
    site = await session.get(Site, site_id)
    if site is None or site.deleted_at is not None:
        raise HTTPException(status_code=404, detail=f"no such site {site_id}")
    return site


@router.get("/api/v1/policy-sites", response_model=list[SiteOut])
async def list_sites(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[SiteOut]:
    """Policy sites — a scope defined by **subnets**, not by membership.

    A host belongs to a site when its primary IP falls inside one of the site's CIDRs, so membership
    is derived and needs no per-host bookkeeping: move a machine to another network and its site
    follows. Sites sit in the precedence chain **global < group < OU < site < host**, and each lives
    inside an OU for tree placement.
    """
    rows = (
        await session.scalars(
            select(Site).where(Site.tenant_id == DEFAULT_TENANT_ID, Site.deleted_at.is_(None)).order_by(Site.name)
        )
    ).all()
    return [_to_out(s) for s in rows]


@router.post("/api/v1/policy-sites", response_model=SiteOut)
async def create_site(
    body: SiteIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> SiteOut:
    """Create a site. 422 for an empty name, 409 when the name is taken.

    Its subnets decide which hosts it covers — a site with none covers nothing, which is a valid
    intermediate state rather than an error.
    """
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    site = Site(
        id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=body.name, description=body.description,
        ou_id=body.ou_id, subnets=_validate_cidrs(body.subnets),
    )
    session.add(site)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a site named {body.name!r} already exists") from exc
    return _to_out(site)


@router.put("/api/v1/policy-sites/{site_id}", response_model=SiteOut)
async def update_site(
    site_id: UUID, body: SiteIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> SiteOut:
    """Replace a site's fields wholesale — an omitted field is cleared. Use PATCH for one field."""
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    site = await _get_site_or_404(session, site_id)
    site.name = body.name
    site.description = body.description
    site.ou_id = body.ou_id
    site.subnets = _validate_cidrs(body.subnets)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a site named {body.name!r} already exists") from exc
    return _to_out(site)


class SitePatch(BaseModel):
    # Re-scope to another OU (palette drag-to-link) — partial update.
    ou_id: UUID | None = None


@router.patch("/api/v1/policy-sites/{site_id}", response_model=SiteOut)
async def patch_site(
    site_id: UUID, body: SitePatch, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> SiteOut:
    """Change individual fields of a site; anything omitted stays as it is.

    Re-placing it in another OU is checked here (422 for an OU that does not exist), because a site
    hanging off nothing would drop out of the tree the precedence chain walks.
    """
    site = await _get_site_or_404(session, site_id)
    if body.ou_id is not None:
        if await session.get(OUNode, body.ou_id) is None:
            raise HTTPException(status_code=422, detail=f"no such OU {body.ou_id}")
        site.ou_id = body.ou_id
    await session.commit()
    return _to_out(site)


@router.delete("/api/v1/policy-sites/{site_id}", status_code=204)
async def delete_site(
    site_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    """Delete a site.

    Policies and links scoped to it go with it (`ON DELETE CASCADE`), so hosts inside its subnets
    lose whatever that site contributed. They keep everything from the other scopes — global, group,
    OU and their own — which is why a delete here usually changes less than it looks.

    Not immediate on the hosts: see `replace_site_subnets` for when a membership change lands.
    """
    site = await _get_site_or_404(session, site_id)
    await session.delete(site)  # config_policies.site_id / links.site_id are ON DELETE CASCADE
    await session.commit()


class SubnetsIn(BaseModel):
    cidrs: list[str]


@router.put("/api/v1/policy-sites/{site_id}/subnets", response_model=SiteOut)
async def replace_site_subnets(
    site_id: UUID, body: SubnetsIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> SiteOut:
    """Replace the site's CIDRs — which silently changes **which hosts it covers**.

    Every CIDR is validated (422 naming the bad one) so a typo cannot create a site that matches
    nothing while looking configured.

    **When it takes effect:** not at once. Unlike an orchestration link — which recompiles the
    affected hosts before returning — a subnet change alters *derived* membership, and no host is
    named at the moment of the write. The convergence sweep (`converge_once`, and
    `POST /api/v1/config-sync/run` to force it) recompiles every host and pushes what changed, which
    is exactly the case its own docstring calls "mutations whose endpoint never enqueued a policy
    event". So this is eventually consistent by design; if you need it now, run the sweep.
    """
    site = await _get_site_or_404(session, site_id)
    site.subnets = _validate_cidrs(body.cidrs)
    await session.commit()
    return _to_out(site)
