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

from sqlalchemy import select, update as sa_update
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Dashboard, DashboardWidget, Metric
from bossman.services import search as search_svc
from bossman.services.monitoring import fleet_hosts, fleet_summary, query_problems

# The widget catalog this dashboard actually computes data for — the honest
# data-backed subset offered in the add-widget dialog.
WIDGET_TYPES = ("top_hosts", "problems", "gauge", "timeseries", "donut", "stat")

# The full render set (matches the DB check constraint + the UI renderer). The
# extra 8 are AI-emitted widgets that carry their payload in config['static']
# rather than being computed here — valid to persist, just not in the catalog.
WIDGET_TYPES_ALL = WIDGET_TYPES + (
    "bar", "table", "status_tiles", "progress", "ai_summary", "war_room", "log", "callout",
)


async def list_dashboards(session: AsyncSession, username: str) -> list[Dashboard]:
    return list(
        (
            await session.scalars(
                select(Dashboard).where(Dashboard.username == username).order_by(Dashboard.created_at)
            )
        ).all()
    )


async def ensure_default_dashboard(session: AsyncSession, username: str) -> Dashboard:
    """Every operator has at least one dashboard. Returns the user's default,
    creating a first "Fleet Overview" if they have none yet (new users)."""
    existing = await list_dashboards(session, username)
    if existing:
        return next((d for d in existing if d.is_default), existing[0])
    dash = Dashboard(username=username, name="Fleet Overview", is_default=True, source="manual")
    session.add(dash)
    await session.commit()
    return dash


async def create_dashboard(
    session: AsyncSession, username: str, *, name: str, source: str = "manual", prompt: str = "",
) -> Dashboard:
    make_default = not await list_dashboards(session, username)
    dash = Dashboard(username=username, name=name, source=source, prompt=prompt, is_default=make_default)
    session.add(dash)
    await session.commit()
    return dash


async def update_dashboard(
    session: AsyncSession, username: str, dashboard_id: UUID, *,
    name: str | None = None, is_default: bool | None = None, context: dict | None = None,
) -> Dashboard | None:
    dash = await session.get(Dashboard, dashboard_id)
    if dash is None or dash.username != username:
        return None
    if name is not None:
        dash.name = name
    if context is not None:
        dash.context = context
    if is_default:
        # Exactly one default per user.
        await session.execute(
            sa_update(Dashboard).where(Dashboard.username == username).values(is_default=False)
        )
        dash.is_default = True
    dash.updated_at = datetime.now(timezone.utc)
    await session.commit()
    return dash


async def _unique_name(session: AsyncSession, username: str, base: str) -> str:
    """A dashboard name unique per user — append (2), (3), … on collision."""
    existing = {d.name for d in await list_dashboards(session, username)}
    if base not in existing:
        return base
    for i in range(2, 100):
        candidate = f"{base} ({i})"
        if candidate not in existing:
            return candidate
    return f"{base} ({len(existing) + 1})"


async def create_ai_dashboard(
    session: AsyncSession, username: str, prompt: str, specs: list[dict]
) -> Dashboard:
    """Materialize an AI-designed widget spec list into a real, editable
    source='ai' dashboard (Block A3 merge): each spec's inline `data` is stored
    under config['static'] so it renders without recomputation, and the whole
    thing then behaves like any other named dashboard (pick/rename/edit/delete)."""
    name = await _unique_name(session, username, f"AI · {(prompt or 'dashboard').strip()[:32]}")
    dash = Dashboard(username=username, name=name, source="ai", prompt=prompt, is_default=False)
    session.add(dash)
    await session.flush()  # need dash.id for the widgets
    for spec in specs:
        wtype = spec.get("widget_type")
        if wtype not in WIDGET_TYPES_ALL:
            continue
        default_w, default_h = DEFAULT_SIZE.get(wtype, (4, 3))
        session.add(
            DashboardWidget(
                dashboard_id=dash.id,
                username=username,
                widget_type=wtype,
                title=spec.get("title", ""),
                gs_x=int(spec.get("gs_x", 0) or 0),
                gs_y=int(spec.get("gs_y", 0) or 0),
                gs_w=int(spec.get("gs_w") or default_w),
                gs_h=int(spec.get("gs_h") or default_h),
                config={"static": spec.get("data")},
            )
        )
    await session.commit()
    return dash


async def delete_dashboard(session: AsyncSession, username: str, dashboard_id: UUID) -> bool:
    dash = await session.get(Dashboard, dashboard_id)
    if dash is None or dash.username != username:
        return False
    was_default = dash.is_default
    await session.delete(dash)  # cascades to its widgets
    await session.commit()
    if was_default:
        # Promote another dashboard to default so the user always has one.
        remaining = await list_dashboards(session, username)
        if remaining:
            remaining[0].is_default = True
            await session.commit()
    return True

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


async def list_widgets(
    session: AsyncSession, username: str, dashboard_id: UUID | None = None
) -> list[DashboardWidget]:
    """Widgets of one dashboard (scoped by username for authz). Without a
    dashboard_id, falls back to the user's default dashboard so the legacy
    flat endpoint keeps working during the UI transition."""
    if dashboard_id is None:
        dashboard_id = (await ensure_default_dashboard(session, username)).id
    return list(
        (
            await session.scalars(
                select(DashboardWidget)
                .where(DashboardWidget.username == username, DashboardWidget.dashboard_id == dashboard_id)
                .order_by(DashboardWidget.created_at)
            )
        ).all()
    )


async def create_widget(
    session: AsyncSession,
    username: str,
    *,
    dashboard_id: UUID | None = None,
    widget_type: str,
    title: str,
    gs_x: int = 0,
    gs_y: int = 0,
    gs_w: int | None = None,
    gs_h: int | None = None,
    config: dict | None = None,
) -> DashboardWidget:
    if dashboard_id is None:
        dashboard_id = (await ensure_default_dashboard(session, username)).id
    default_w, default_h = DEFAULT_SIZE.get(widget_type, (4, 3))
    widget = DashboardWidget(
        dashboard_id=dashboard_id,
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


async def _metric_series(session: AsyncSession, cfg: dict, settings) -> dict[str, Any]:
    """A timeseries widget's data — from a saved graph, or from one inline agent+metric.

    Both go through services/graph_data, which is what makes the widget and the graph the
    same chart rather than two implementations. This used to run its own `select(Metric)`
    with no tier selection, so a long lookback pulled every raw row while the identical
    range in a graph came back downsampled; that is gone.

    `config.graph_id` is the reusable form: the chart is authored once as a Graph (several
    hosts, per-series colour/axis/function) and a dashboard widget is a PLACE that shows it.
    `config.agent_id` + `config.metric` stays supported — it is the same computation with an
    implicit one-item graph, and existing widgets keep working.
    """
    from types import SimpleNamespace

    from bossman.services.graph_data import load_graph, series_for_items

    since_dt = datetime.fromtimestamp(
        datetime.now(timezone.utc).timestamp() - cfg.get("lookback_seconds", 3600), tz=timezone.utc
    )

    graph_id = cfg.get("graph_id")
    if graph_id:
        graph = await load_graph(session, graph_id)
        if graph is None:
            # Named, not empty: a widget pointing at a deleted graph must say so, or it looks
            # like a metric with no data.
            return {"series": [], "error": f"the saved graph {graph_id} no longer exists"}
        return {
            "graph": {"id": str(graph.id), "name": graph.name, "graph_type": graph.graph_type,
                      "show_legend": graph.show_legend},
            "series": await series_for_items(session, settings, graph.items, since_dt),
        }

    agent_id = cfg.get("agent_id")
    metric = cfg.get("metric")
    if not agent_id or not metric:
        return {"points": [], "error": "config.graph_id, or config.agent_id and config.metric, are required"}
    # One implicit item, so the inline case takes the identical code path (including tier
    # selection) instead of a second, simpler one that drifts.
    item = SimpleNamespace(
        id=None, agent_id=agent_id, metric=metric, label=cfg.get("label") or metric,
        color=cfg.get("color", "#1e9600"), draw_style="line", axis_side="left",
        function=cfg.get("function", "avg"),
    )
    series = await series_for_items(session, settings, [item], since_dt)
    # `points` stays at the top level for the existing single-series renderer; `series` is
    # added so one renderer can handle both shapes.
    return {"points": series[0]["points"], "resolution": series[0]["resolution"], "series": series}


def _apply_host_context(hosts: list, context: dict) -> list:
    """Scope a host list by the dashboard's filter context (Checkmk-style):
    `host` = case-insensitive name substring, `state` = host state rollup."""
    host_q = (context.get("host") or "").strip().lower()
    state = (context.get("state") or "").strip().upper()
    out = hosts
    if host_q:
        out = [h for h in out if host_q in (h.name or "").lower()]
    if state:
        out = [h for h in out if getattr(h, "state_rollup", None) == state]
    return out


def _apply_problem_context(problems: list, context: dict) -> list:
    host_q = (context.get("host") or "").strip().lower()
    state = (context.get("state") or "").strip().upper()
    out = problems
    if host_q:
        out = [p for p in out if host_q in (getattr(p, "agent_name", "") or "").lower()]
    if state:
        out = [p for p in out if getattr(p, "state", None) == state]
    return out


async def widget_data(
    session: AsyncSession,
    widget: DashboardWidget,
    context: dict | None = None,
    settings=None,
) -> dict[str, Any]:
    """Computes the current data payload for one widget, dispatched on its
    widget_type — the counterpart to CentralStation's own per-widget
    `/dashboard-widgets/{id}/data` endpoint. Each type's shape is
    deliberately minimal JSON the frontend's polymorphic renderer maps
    straight onto an ECharts option builder."""
    cfg = widget.config or {}
    ctx = context or {}
    # Only the timeseries branch needs settings (the metric tier thresholds live there).
    # Resolved here rather than made mandatory, so the existing callers and tests that ask
    # for a stat or top_hosts payload do not have to thread a Settings through.
    if settings is None:
        from bossman.config import get_settings as _get_settings

        settings = _get_settings()
    # AI-generated widgets carry their payload inline (Block W2 → unified model);
    # serve it as-is rather than recomputing from a data source.
    if "static" in cfg:
        return cfg["static"] or {}
    if widget.widget_type == "top_hosts":
        hosts = _apply_host_context(await fleet_hosts(session), ctx)
        limit = cfg.get("limit", 10)
        return {"hosts": [_host_dict(h) for h in hosts[:limit]]}
    if widget.widget_type == "problems":
        limit = cfg.get("limit", 10)
        problems = _apply_problem_context(await query_problems(session), ctx)
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
        return await _metric_series(session, cfg, settings)
    # A query-backed table widget (P4): a pinned fleet search. config.query is
    # re-run live each time the widget loads, so the widget IS a saved search.
    if widget.widget_type == "table" and cfg.get("query"):
        q = cfg["query"]
        kind = cfg.get("kind", "services")
        limit = int(cfg.get("limit", 10))
        node = search_svc.parse_query(q)
        if kind == "hosts":
            hosts = await search_svc.search_hosts(session, node, limit=limit)
            rollups = await search_svc.worst_states(session, [h.id for h in hosts])
            return {
                "columns": ["State", "Host", "Criticality", "Site"],
                "rows": [[rollups.get(h.id, "OK"), h.name, h.criticality or "—", h.site or "—"] for h in hosts],
            }
        rows = await search_svc.search_services(session, node, limit=limit)
        return {
            "columns": ["State", "Host", "Service"],
            "rows": [[s.state, a.name, s.name] for s, a in rows],
        }
    return {}
