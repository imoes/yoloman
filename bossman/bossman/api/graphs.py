"""Custom multi-host graphs CRUD + data (Zabbix gap-analysis Block K11): a
saved, reusable chart combining items from several hosts — unlike the
dashboard's per-widget ad-hoc series, this is a named, editable object
(bundle it into a Template in Block K12 once both exist).
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.models import Graph, GraphItem
from bossman.db.session import get_session
from bossman.services.graph_data import series_for_items

router = APIRouter()

# Graph.items is a lazy relationship; AsyncSession can't lazy-load it
# outside an explicit await (that's exactly what raised
# sqlalchemy.exc.MissingGreenlet — found via real, reproducible test
# failures, not by inspection). Every query that hands a Graph to
# GraphOut.from_model() must eager-load items via this, since
# from_model() is a plain sync classmethod with no await of its own.
_WITH_ITEMS = selectinload(Graph.items)

_DRAW_STYLES = ("line", "bold_line", "filled", "dot", "dashed", "gradient")
_AXIS_SIDES = ("left", "right")
_FUNCTIONS = ("avg", "min", "max", "last")
_GRAPH_TYPES = ("normal", "stacked")


class GraphItemIn(BaseModel):
    agent_id: UUID
    metric: str
    label: str | None = None
    color: str = "#1e9600"
    draw_style: str = "line"
    axis_side: str = "left"
    function: str = "avg"
    sort_order: int = 0


class GraphItemOut(GraphItemIn):
    id: UUID

    @classmethod
    def from_model(cls, i: GraphItem) -> "GraphItemOut":
        return cls(
            id=i.id, agent_id=i.agent_id, metric=i.metric, label=i.label, color=i.color,
            draw_style=i.draw_style, axis_side=i.axis_side, function=i.function, sort_order=i.sort_order,
        )


class GraphIn(BaseModel):
    name: str
    graph_type: str = "normal"
    y_axis_mode: str = "calculated"
    show_legend: bool = True
    show_working_time: bool = False
    items: list[GraphItemIn] = []


class GraphOut(BaseModel):
    id: UUID
    name: str
    graph_type: str
    y_axis_mode: str
    show_legend: bool
    show_working_time: bool
    created_at: datetime
    items: list[GraphItemOut]

    @classmethod
    def from_model(cls, g: Graph) -> "GraphOut":
        return cls(
            id=g.id, name=g.name, graph_type=g.graph_type, y_axis_mode=g.y_axis_mode,
            show_legend=g.show_legend, show_working_time=g.show_working_time, created_at=g.created_at,
            items=[GraphItemOut.from_model(i) for i in g.items],
        )


def _validate(body: GraphIn) -> None:
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    if body.graph_type not in _GRAPH_TYPES:
        raise HTTPException(status_code=422, detail=f"graph_type must be one of {_GRAPH_TYPES}")
    for item in body.items:
        if item.draw_style not in _DRAW_STYLES:
            raise HTTPException(status_code=422, detail=f"draw_style must be one of {_DRAW_STYLES}")
        if item.axis_side not in _AXIS_SIDES:
            raise HTTPException(status_code=422, detail=f"axis_side must be one of {_AXIS_SIDES}")
        if item.function not in _FUNCTIONS:
            raise HTTPException(status_code=422, detail=f"function must be one of {_FUNCTIONS}")


async def _get_graph_or_404(session: AsyncSession, graph_id: UUID) -> Graph:
    graph = await session.scalar(select(Graph).options(_WITH_ITEMS).where(Graph.id == graph_id))
    if graph is None:
        raise HTTPException(status_code=404, detail=f"no such graph {graph_id}")
    return graph


@router.get("/api/v1/graphs", response_model=list[GraphOut])
async def list_graphs(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[GraphOut]:
    rows = (await session.scalars(select(Graph).options(_WITH_ITEMS).order_by(Graph.name))).all()
    return [GraphOut.from_model(g) for g in rows]


@router.get("/api/v1/graphs/{graph_id}", response_model=GraphOut)
async def get_graph(
    graph_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> GraphOut:
    return GraphOut.from_model(await _get_graph_or_404(session, graph_id))


@router.post("/api/v1/graphs", response_model=GraphOut)
async def create_graph(
    body: GraphIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> GraphOut:
    _validate(body)
    graph = Graph(
        name=body.name, graph_type=body.graph_type, y_axis_mode=body.y_axis_mode,
        show_legend=body.show_legend, show_working_time=body.show_working_time,
        items=[GraphItem(**item.model_dump()) for item in body.items],
    )
    session.add(graph)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a graph named {body.name!r} already exists") from exc
    await session.refresh(graph, attribute_names=["items"])
    return GraphOut.from_model(graph)


@router.put("/api/v1/graphs/{graph_id}", response_model=GraphOut)
async def update_graph(
    graph_id: UUID,
    body: GraphIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> GraphOut:
    _validate(body)
    graph = await _get_graph_or_404(session, graph_id)
    graph.name = body.name
    graph.graph_type = body.graph_type
    graph.y_axis_mode = body.y_axis_mode
    graph.show_legend = body.show_legend
    graph.show_working_time = body.show_working_time
    # Replace-all for items, matching the check-rule/notification-rule
    # dialogs' "whole form, not a diff" editing shape — cascade delete-
    # orphan (see the Graph.items relationship) removes the old rows.
    graph.items = [GraphItem(**item.model_dump()) for item in body.items]
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a graph named {body.name!r} already exists") from exc
    await session.refresh(graph, attribute_names=["items"])
    return GraphOut.from_model(graph)


@router.delete("/api/v1/graphs/{graph_id}", status_code=204)
async def delete_graph(
    graph_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    graph = await _get_graph_or_404(session, graph_id)
    await session.delete(graph)
    await session.commit()


class GraphSeriesOut(BaseModel):
    item_id: UUID
    agent_id: UUID
    metric: str
    label: str | None
    color: str
    draw_style: str
    axis_side: str
    resolution: str
    points: list[dict]


class GraphDataOut(BaseModel):
    graph: GraphOut
    series: list[GraphSeriesOut]


@router.get("/api/v1/graphs/{graph_id}/data", response_model=GraphDataOut)
async def get_graph_data(
    graph_id: UUID,
    since: datetime | None = Query(None, description="Only points at or after this time"),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> GraphDataOut:
    """Combined series data for every item in the graph, one call — each
    item's tier (raw/hourly/daily) is picked independently by
    metrics_query.query_series based on `since`'s age, same as a plain
    per-agent metric series. `function` selects which of the tier's
    value/min_value/max_value to plot; "last" (Zabbix's pie-only function)
    behaves like "avg" here since graphs are line-based, not pie."""
    graph = await _get_graph_or_404(session, graph_id)
    # The computation itself lives in services/graph_data so the dashboard's timeseries
    # widget renders the SAME series from the SAME code — see that module's header for the
    # two implementations this replaced.
    series = [GraphSeriesOut(**row) for row in await series_for_items(session, settings, graph.items, since)]
    return GraphDataOut(graph=GraphOut.from_model(graph), series=series)
