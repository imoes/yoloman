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

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.db.models import Agent, Service
from bossman.db.session import get_session
from bossman.services import search as search_svc

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
    node = search_svc.parse_query(q)
    return {"host_groups": await search_svc.search_groups(session, node, limit=limit)}


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
