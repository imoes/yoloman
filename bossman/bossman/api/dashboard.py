"""GET/POST/PATCH/DELETE /api/v1/dashboard-widgets + GET .../{id}/data — the
per-operator GridStack dashboard REST surface (see docs/plan.md's
monitoring-cockpit ergänzung Block F5). Every route auth-gated like the
rest of Block B7's surface; widgets are scoped to the calling identity's
own username (services.dashboard.update_widget/delete_widget already
enforce this, returning None/False rather than leaking another operator's
widget's existence).
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from bossman.api.auth import get_current_identity
from bossman.db.models import Dashboard, DashboardWidget
from bossman.db.session import get_session
from bossman.services.dashboard import (
    WIDGET_TYPES_ALL,
    create_dashboard,
    create_widget,
    delete_dashboard,
    delete_widget,
    ensure_default_dashboard,
    list_dashboards,
    list_widgets,
    update_dashboard,
    update_widget,
    widget_data,
)
from sqlalchemy.ext.asyncio import AsyncSession

router = APIRouter()


class DashboardOut(BaseModel):
    id: UUID
    name: str
    is_default: bool
    source: str
    prompt: str
    context: dict[str, Any]
    created_at: datetime

    @classmethod
    def from_model(cls, d: Dashboard) -> "DashboardOut":
        return cls(
            id=d.id, name=d.name, is_default=d.is_default, source=d.source,
            prompt=d.prompt, context=d.context or {}, created_at=d.created_at,
        )


class CreateDashboardRequest(BaseModel):
    name: str
    source: str = "manual"
    prompt: str = ""


class UpdateDashboardRequest(BaseModel):
    name: str | None = None
    is_default: bool | None = None


@router.get("/api/v1/dashboards", response_model=list[DashboardOut])
async def list_dashboards_route(
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> list[DashboardOut]:
    await ensure_default_dashboard(session, identity.name)  # new users always have one
    return [DashboardOut.from_model(d) for d in await list_dashboards(session, identity.name)]


@router.post("/api/v1/dashboards", response_model=DashboardOut)
async def create_dashboard_route(
    body: CreateDashboardRequest,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> DashboardOut:
    dash = await create_dashboard(session, identity.name, name=body.name, source=body.source, prompt=body.prompt)
    return DashboardOut.from_model(dash)


@router.patch("/api/v1/dashboards/{dashboard_id}", response_model=DashboardOut)
async def update_dashboard_route(
    dashboard_id: UUID,
    body: UpdateDashboardRequest,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> DashboardOut:
    dash = await update_dashboard(session, identity.name, dashboard_id, name=body.name, is_default=body.is_default)
    if dash is None:
        raise HTTPException(status_code=404, detail=f"no such dashboard {dashboard_id}")
    return DashboardOut.from_model(dash)


@router.delete("/api/v1/dashboards/{dashboard_id}", status_code=204)
async def delete_dashboard_route(
    dashboard_id: UUID,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> None:
    if not await delete_dashboard(session, identity.name, dashboard_id):
        raise HTTPException(status_code=404, detail=f"no such dashboard {dashboard_id}")


class DashboardWidgetOut(BaseModel):
    id: UUID
    dashboard_id: UUID | None
    widget_type: str
    title: str
    gs_x: int
    gs_y: int
    gs_w: int
    gs_h: int
    config: dict[str, Any]
    pinned: bool
    hidden: bool
    created_at: datetime

    @classmethod
    def from_model(cls, w: DashboardWidget) -> "DashboardWidgetOut":
        return cls(
            id=w.id,
            dashboard_id=w.dashboard_id,
            widget_type=w.widget_type,
            title=w.title,
            gs_x=w.gs_x,
            gs_y=w.gs_y,
            gs_w=w.gs_w,
            gs_h=w.gs_h,
            config=w.config,
            pinned=w.pinned,
            hidden=w.hidden,
            created_at=w.created_at,
        )


class CreateWidgetRequest(BaseModel):
    widget_type: str
    title: str
    dashboard_id: UUID | None = None
    gs_x: int = 0
    gs_y: int = 0
    gs_w: int | None = None
    gs_h: int | None = None
    config: dict[str, Any] = {}


class UpdateWidgetRequest(BaseModel):
    gs_x: int | None = None
    gs_y: int | None = None
    gs_w: int | None = None
    gs_h: int | None = None
    title: str | None = None
    config: dict[str, Any] | None = None
    pinned: bool | None = None
    hidden: bool | None = None


@router.get("/api/v1/dashboard-widgets", response_model=list[DashboardWidgetOut])
async def list_dashboard_widgets(
    dashboard_id: UUID | None = None,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> list[DashboardWidgetOut]:
    widgets = await list_widgets(session, identity.name, dashboard_id)
    return [DashboardWidgetOut.from_model(w) for w in widgets]


# Dashboard-scoped alias — the same list/create, addressed by dashboard.
@router.get("/api/v1/dashboards/{dashboard_id}/widgets", response_model=list[DashboardWidgetOut])
async def list_widgets_of_dashboard(
    dashboard_id: UUID,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> list[DashboardWidgetOut]:
    widgets = await list_widgets(session, identity.name, dashboard_id)
    return [DashboardWidgetOut.from_model(w) for w in widgets]


@router.post("/api/v1/dashboard-widgets", response_model=DashboardWidgetOut)
async def create_dashboard_widget(
    body: CreateWidgetRequest,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> DashboardWidgetOut:
    if body.widget_type not in WIDGET_TYPES_ALL:
        raise HTTPException(status_code=422, detail=f"widget_type must be one of {WIDGET_TYPES_ALL}")
    widget = await create_widget(
        session,
        identity.name,
        dashboard_id=body.dashboard_id,
        widget_type=body.widget_type,
        title=body.title,
        gs_x=body.gs_x,
        gs_y=body.gs_y,
        gs_w=body.gs_w,
        gs_h=body.gs_h,
        config=body.config,
    )
    return DashboardWidgetOut.from_model(widget)


@router.patch("/api/v1/dashboard-widgets/{widget_id}", response_model=DashboardWidgetOut)
async def update_dashboard_widget(
    widget_id: UUID,
    body: UpdateWidgetRequest,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> DashboardWidgetOut:
    widget = await update_widget(
        session,
        identity.name,
        widget_id,
        gs_x=body.gs_x,
        gs_y=body.gs_y,
        gs_w=body.gs_w,
        gs_h=body.gs_h,
        title=body.title,
        config=body.config,
        pinned=body.pinned,
        hidden=body.hidden,
    )
    if widget is None:
        raise HTTPException(status_code=404, detail=f"no such widget {widget_id}")
    return DashboardWidgetOut.from_model(widget)


@router.delete("/api/v1/dashboard-widgets/{widget_id}", status_code=204)
async def delete_dashboard_widget(
    widget_id: UUID,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> None:
    deleted = await delete_widget(session, identity.name, widget_id)
    if not deleted:
        raise HTTPException(status_code=404, detail=f"no such widget {widget_id}")


@router.get("/api/v1/dashboard-widgets/{widget_id}/data")
async def get_dashboard_widget_data(
    widget_id: UUID,
    session: AsyncSession = Depends(get_session),
    identity=Depends(get_current_identity),
) -> dict[str, Any]:
    widgets = await list_widgets(session, identity.name)
    widget = next((w for w in widgets if w.id == widget_id), None)
    if widget is None:
        raise HTTPException(status_code=404, detail=f"no such widget {widget_id}")
    return await widget_data(session, widget)
