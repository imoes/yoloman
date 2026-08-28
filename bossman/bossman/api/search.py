"""The Checkmk-style fleet-search REST surface.

- GET /api/v1/search             — unified, capped, grouped preview for the
                                    live omnibox dropdown (hosts + groups +
                                    services in one typed response).
- GET /api/v1/search/hosts       — the full, paginated "hosts matching X" view.
- GET /api/v1/search/services    — the full, paginated "service-checks matching
                                    X" view (the fleet-wide list that did not
                                    exist before — /problems is problem-only).
- GET /api/v1/search/host-groups — matching flat group names.

The query language + compilation lives in services/search.py; the same parse
backs both the dropdown and the result views so search == manual filtering.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import delete as sa_delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity
from bossman.db.models import DEFAULT_TENANT_ID, Agent, SavedSearch, Service
from bossman.db.session import get_session
from bossman.services import search as search_svc
from bossman.services.fleet_search import fleet_search

router = APIRouter()


class HostResult(BaseModel):
    id: UUID
    name: str
    address: str | None
    criticality: str | None
    site: str | None
    groups: list[str]
    enrollment_state: str
    last_seen_at: datetime | None
    state_rollup: str

    @classmethod
    def from_agent(cls, a: Agent, state_rollup: str) -> "HostResult":
        return cls(
            id=a.id, name=a.name, address=a.address, criticality=a.criticality,
            site=a.site, groups=list(a.groups or []), enrollment_state=a.enrollment_state,
            last_seen_at=a.last_seen_at, state_rollup=state_rollup,
        )


class ServiceResult(BaseModel):
    id: UUID
    agent_id: UUID
    host: str
    name: str
    metric: str
    state: str
    value: float | None
    output: str
    criticality: str | None
    site: str | None
    last_checked: datetime


class SearchResultItem(BaseModel):
    """One grouped dropdown row."""
    type: str  # host | host_group | service
    id: UUID | None = None  # the host/agent id for a deep-link (None for groups)
    title: str
    subtitle: str | None = None
    state: str | None = None
    query_params: dict  # what the frontend routes to (e.g. {"type":"host","q":"h:web01"})


class UnifiedSearchResponse(BaseModel):
    hosts: list[SearchResultItem]
    host_groups: list[SearchResultItem]
    services: list[SearchResultItem]
    counts: dict[str, int]


class HostSearchResponse(BaseModel):
    hosts: list[HostResult]
    total: int


class ServiceSearchResponse(BaseModel):
    services: list[ServiceResult]
    total: int


@router.get("/api/v1/search", response_model=UnifiedSearchResponse)
async def unified_search(
    q: str = Query("", description="Fleet search query (see services/search.py grammar)"),
    limit: int = Query(8, ge=1, le=50, description="Max preview rows per type"),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> UnifiedSearchResponse:
    """The omnibox: hosts, host groups and services for one query, capped per type.

    A grouped preview for a live dropdown, not a result set — `limit` caps **each** type
    (default 8) and `counts` says how many exist beyond what is shown. Host rows carry the
    worst-state rollup so the dropdown can show severity without a second call.

    **An empty query returns nothing here**, deliberately: an omnibox with an empty box should
    offer no dropdown. Note that the paginated views below do the opposite with the same input —
    see `search_hosts`. The query grammar is in `services/search.py` and is shared with the
    result views, so search and manual filtering cannot disagree.
    """
    node = search_svc.parse_query(q)
    if node is None:
        return UnifiedSearchResponse(hosts=[], host_groups=[], services=[], counts={"host": 0, "host_group": 0, "service": 0})

    hosts = await search_svc.search_hosts(session, node, limit=limit)
    groups = await search_svc.search_groups(session, node, limit=limit)
    services = await search_svc.search_services(session, node, limit=limit)
    rollups = await search_svc.worst_states(session, [h.id for h in hosts])

    host_items = [
        SearchResultItem(
            type="host", id=h.id, title=h.name, subtitle=h.address, state=rollups.get(h.id, "OK"),
            query_params={"type": "host", "q": f'h:"{h.name}"'},
        )
        for h in hosts
    ]
    group_items = [
        SearchResultItem(type="host_group", title=g, query_params={"type": "host", "q": f'hg:"{g}"'})
        for g in groups
    ]
    service_items = [
        SearchResultItem(
            type="service", id=a.id, title=s.name, subtitle=a.name, state=s.state,
            query_params={"type": "service", "q": f's:"{s.name}"'},
        )
        for s, a in services
    ]
    return UnifiedSearchResponse(
        hosts=host_items, host_groups=group_items, services=service_items,
        counts={"host": len(host_items), "host_group": len(group_items), "service": len(service_items)},
    )


@router.get("/api/v1/search/hosts", response_model=HostSearchResponse)
async def search_hosts(
    q: str = Query(""),
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> HostSearchResponse:
    """Hosts matching the query, paginated, with the unpaginated `total`.

    **An empty query matches EVERY host** — the opposite of the omnibox, which returns nothing for
    the same input. Both are right for their surface (a filter panel with nothing typed shows the
    fleet; a dropdown with nothing typed shows no menu), and a caller carrying an assumption from
    one to the other gets it exactly backwards. Send a query, or mean "all".

    Infrastructure agents are excluded, as everywhere a *host* is listed: the silent SNMP/SSH
    poller is not a monitored host. Each row carries the worst-state rollup of its services.
    """
    node = search_svc.parse_query(q)
    hosts = await search_svc.search_hosts(session, node, limit=limit, offset=offset)
    total = await search_svc.count_hosts(session, node)
    rollups = await search_svc.worst_states(session, [h.id for h in hosts])
    return HostSearchResponse(
        hosts=[HostResult.from_agent(h, rollups.get(h.id, "OK")) for h in hosts], total=total
    )


@router.get("/api/v1/search/services", response_model=ServiceSearchResponse)
async def search_services(
    q: str = Query(""),
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> ServiceSearchResponse:
    """Service checks matching the query, fleet-wide and paginated.

    The list `/api/v1/problems` cannot give you: **every** matching service with its state, not
    only the ones that are not OK. That is the difference between asking "how is this check doing
    everywhere" and "what is broken".

    Each row carries its host's name, criticality and site, so a caller does not need to join
    against the fleet listing to sort or group by them. An empty query matches everything, as in
    `search_hosts`.
    """
    node = search_svc.parse_query(q)
    rows = await search_svc.search_services(session, node, limit=limit, offset=offset)
    total = await search_svc.count_services(session, node)
    services = [
        ServiceResult(
            id=s.id, agent_id=s.agent_id, host=a.name, name=s.name, metric=s.metric,
            state=s.state, value=s.value, output=s.output, criticality=a.criticality,
            site=a.site, last_checked=s.last_checked,
        )
        for s, a in rows
    ]
    return ServiceSearchResponse(services=services, total=total)


@router.get("/api/v1/search/host-groups")
async def search_host_groups(
    q: str = Query(""),
    limit: int = Query(50, ge=1, le=200),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """Host groups whose names match the query. Flat names, capped by `limit`."""
    node = search_svc.parse_query(q)
    return {"host_groups": await search_svc.search_groups(session, node, limit=limit)}


@router.get("/api/v1/fleet/search")
async def fleet_search_route(
    q: str = Query("", description="substring, or key=value (path contains key AND value contains value)"),
    per_host: int = Query(50, ge=1, le=500),
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """Fleet-wide search across every host's compiled desired_state — config
    keys/values, variables, tags, facts, applied checks/roles/thresholds — in one
    call. Backs the fleet-search view and the MCP fleet_search tool."""
    return await fleet_search(session, q, per_host=per_host)


@router.get("/api/v1/tags")
async def list_tags(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """Distinct tag keys → values across the fleet, for tag: autocomplete."""
    return {"tags": await search_svc.distinct_tags(session)}


@router.get("/api/v1/sites")
async def list_sites(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """Distinct site values across the fleet, for site: autocomplete."""
    return {"sites": await search_svc.distinct_sites(session)}


# ── Saved searches (Fleet-search P3 — Checkmk saved-views parity) ──────────

class SavedSearchIn(BaseModel):
    name: str
    query: str


def _saved_out(s: SavedSearch) -> dict:
    return {"id": str(s.id), "name": s.name, "query": s.query,
            "created_by": s.created_by, "created_at": s.created_at.isoformat()}


@router.get("/api/v1/saved-searches")
async def list_saved_searches(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> dict:
    """The tenant's named Fleet-search queries, alphabetical — the recall list."""
    rows = (await session.scalars(
        select(SavedSearch).where(SavedSearch.tenant_id == DEFAULT_TENANT_ID).order_by(SavedSearch.name))).all()
    return {"searches": [_saved_out(s) for s in rows]}


@router.post("/api/v1/saved-searches")
async def create_saved_search(
    body: SavedSearchIn,
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> dict:
    """Save (or overwrite by name) a Fleet-search query for later recall."""
    name, query = body.name.strip(), body.query.strip()
    if not name or not query:
        raise HTTPException(status_code=422, detail="name and query are required")
    existing = await session.scalar(
        select(SavedSearch).where(SavedSearch.tenant_id == DEFAULT_TENANT_ID, SavedSearch.name == name))
    if existing is not None:
        existing.query = query
        existing.created_by = identity.name
    else:
        session.add(SavedSearch(tenant_id=DEFAULT_TENANT_ID, name=name, query=query, created_by=identity.name))
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a saved search named {name!r} already exists") from None
    row = await session.scalar(
        select(SavedSearch).where(SavedSearch.tenant_id == DEFAULT_TENANT_ID, SavedSearch.name == name))
    return _saved_out(row)


@router.delete("/api/v1/saved-searches/{search_id}", status_code=204)
async def delete_saved_search(
    search_id: UUID,
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> None:
    """Delete a saved search.

    **204 whether or not it existed** — a delete states an end condition that holds either way, and
    a 404 would make a retry look like a failure.

    A saved search is **tenant-scoped and shared** by everyone in the tenant, not private to
    whoever made it; `created_by` records the author but confers no ownership. So this removes it
    for your colleagues too, and the endpoint does not ask whether you were the author.
    """
    await session.execute(sa_delete(SavedSearch).where(SavedSearch.id == search_id))
    await session.commit()
