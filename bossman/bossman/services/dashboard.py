"""Bossman's per-operator dashboard: freely arranged GridStack widgets on
the Fleet Overview page (see docs/plan.md's monitoring-cockpit ergänzung
Block F5, modeled directly on CentralStation's own dashboard-widget
architecture — one data-record-per-widget persisted server-side, a single
polymorphic renderer client-side, rather than a component-per-type
registry). Framework-free (no FastAPI import), like every other services/
module in this project.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import DashboardWidget, Metric
from bossman.services.monitoring import fleet_hosts, fleet_summary, query_problems

# The widget catalog this dashboard actually supports — deliberately a
# small, honest subset of CentralStation's own type union: only types
# with a real Bossman data source behind them (no "grafana_panel",
# "war_room", "ai_summary", ... which nothing in this project produces).
WIDGET_TYPES = ("top_hosts", "problems", "gauge", "timeseries", "donut", "stat")

# Default GridStack geometry per type when a caller doesn't specify one —
# mirrors CentralStation's add-widget-dialog defaults.
DEFAULT_SIZE = {
    "stat": (2, 2),
    "donut": (4, 4),
    "top_hosts": (6, 4),
    "problems": (6, 4),
    "timeseries": (5, 4),
    "gauge": (3, 3),
}


async def list_widgets(session: AsyncSession, username: str) -> list[DashboardWidget]:
    return list(
        (
            await session.scalars(
                select(DashboardWidget).where(DashboardWidget.username == username).order_by(DashboardWidget.created_at)
            )
        ).all()
    )


async def create_widget(
    session: AsyncSession,
    username: str,
    *,
    widget_type: str,
    title: str,
    gs_x: int = 0,
    gs_y: int = 0,
    gs_w: int | None = None,
    gs_h: int | None = None,
    config: dict | None = None,
) -> DashboardWidget:
    default_w, default_h = DEFAULT_SIZE.get(widget_type, (4, 3))
    widget = DashboardWidget(
        username=username,
        widget_type=widget_type,
        title=title,
        gs_x=gs_x,
        gs_y=gs_y,
        gs_w=gs_w if gs_w is not None else default_w,
        gs_h=gs_h if gs_h is not None else default_h,
        config=config or {},
    )
    session.add(widget)
    await session.commit()
    return widget


async def update_widget(
    session: AsyncSession,
    username: str,
    widget_id: UUID,
    *,
    gs_x: int | None = None,
    gs_y: int | None = None,
    gs_w: int | None = None,
    gs_h: int | None = None,
    title: str | None = None,
    config: dict | None = None,
    pinned: bool | None = None,
    hidden: bool | None = None,
) -> DashboardWidget | None:
    """Returns None if the widget doesn't exist or belongs to a different
    operator — a caller can't distinguish "not found" from "not yours"
    from the response alone, which is the point (no existence leak)."""
    widget = await session.get(DashboardWidget, widget_id)
    if widget is None or widget.username != username:
        return None
    if gs_x is not None:
        widget.gs_x = gs_x
    if gs_y is not None:
        widget.gs_y = gs_y
    if gs_w is not None:
        widget.gs_w = gs_w
    if gs_h is not None:
        widget.gs_h = gs_h
    if title is not None:
        widget.title = title
    if config is not None:
        widget.config = config
    if pinned is not None:
        widget.pinned = pinned
    if hidden is not None:
        widget.hidden = hidden
    await session.commit()
    return widget


async def delete_widget(session: AsyncSession, username: str, widget_id: UUID) -> bool:
    widget = await session.get(DashboardWidget, widget_id)
    if widget is None or widget.username != username:
        return False
    await session.delete(widget)
    await session.commit()
    return True


def _host_dict(h) -> dict[str, Any]:
    return {
        "id": str(h.id),
        "name": h.name,
        "parent_name": h.parent_name,
        "state_rollup": h.state_rollup,
        "cpu_load": h.cpu_load,
        "mem_used_pct": h.mem_used_pct,
        "disk_used_pct_max": h.disk_used_pct_max,
    }


def _problem_dict(p) -> dict[str, Any]:
    return {
        "id": str(p.service.id),
        "host": p.agent_name,
        "name": p.service.name,
        "state": p.service.state,
        "last_state_change": p.service.last_state_change.isoformat(),
    }


async def _latest_metric_value(session: AsyncSession, cfg: dict) -> dict[str, Any]:
    agent_id = cfg.get("agent_id")
    metric = cfg.get("metric")
    if not agent_id or not metric:
        return {"value": None, "error": "config.agent_id and config.metric are required"}
    row = await session.scalar(
        select(Metric).where(Metric.agent_id == agent_id, Metric.metric == metric).order_by(Metric.time.desc()).limit(1)
    )
    return {"value": row.value if row else None, "warn": cfg.get("warn"), "crit": cfg.get("crit")}


async def _metric_series(session: AsyncSession, cfg: dict) -> dict[str, Any]:
    agent_id = cfg.get("agent_id")
    metric = cfg.get("metric")
    if not agent_id or not metric:
        return {"points": [], "error": "config.agent_id and config.metric are required"}
    since = datetime.now(timezone.utc).timestamp() - cfg.get("lookback_seconds", 3600)
    since_dt = datetime.fromtimestamp(since, tz=timezone.utc)
    rows = (
        await session.scalars(
            select(Metric)
            .where(Metric.agent_id == agent_id, Metric.metric == metric, Metric.time >= since_dt)
            .order_by(Metric.time)
        )
    ).all()
    return {"points": [{"time": r.time.isoformat(), "value": r.value} for r in rows]}


async def widget_data(session: AsyncSession, widget: DashboardWidget) -> dict[str, Any]:
    """Computes the current data payload for one widget, dispatched on its
    widget_type — the counterpart to CentralStation's own per-widget
    `/dashboard-widgets/{id}/data` endpoint. Each type's shape is
    deliberately minimal JSON the frontend's polymorphic renderer maps
    straight onto an ECharts option builder."""
    cfg = widget.config or {}
    if widget.widget_type == "top_hosts":
        hosts = await fleet_hosts(session)
        limit = cfg.get("limit", 10)
        return {"hosts": [_host_dict(h) for h in hosts[:limit]]}
    if widget.widget_type == "problems":
        limit = cfg.get("limit", 10)
        problems = await query_problems(session)
        return {"problems": [_problem_dict(p) for p in problems[:limit]]}
    if widget.widget_type == "donut":
        summary = await fleet_summary(session)
        return {"buckets": [{"key": k, "count": v} for k, v in summary.services_by_state.items()]}
    if widget.widget_type == "stat":
        summary = await fleet_summary(session)
        source = cfg.get("stat_source", "open_problems")
        value = getattr(summary, source, None) if source in ("hosts_total", "open_problems") else None
        return {"value": value, "label": source}
    if widget.widget_type == "gauge":
        return await _latest_metric_value(session, cfg)
    if widget.widget_type == "timeseries":
        return await _metric_series(session, cfg)
    return {}
