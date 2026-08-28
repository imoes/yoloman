"""The ONE way a chart's series are computed (Block K11 graphs + dashboard timeseries).

Before this, there were two: `api/graphs.py` walked a Graph's items through
`metrics_query.query_series`, which picks the raw/hourly/daily tier from the age of
`since` — while `services/dashboard.py`'s timeseries widget ran its own `select(Metric)`
for one agent+metric with no tier selection at all. Same task, two implementations, and
they did not agree: a 30-day lookback in a dashboard widget pulled every raw row, whereas
the same range in a graph came back downsampled.

That is the parsimony rule with a measurable consequence, so both callers use this module
now. A saved Graph is the reusable, named definition; a dashboard widget is a PLACE that
renders one — either by referencing a graph (`config.graph_id`) or by naming a single
agent+metric inline (`config.agent_id` + `config.metric`), which is the same computation
with an implicit one-item graph.

Returns plain dicts, not Pydantic models: `api/graphs.py` wraps them in GraphSeriesOut and
the dashboard puts them straight into a widget payload. Keeping the shape as data means the
service layer does not depend on either caller's response model.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from bossman.config import Settings
from bossman.db.models import Graph
from bossman.services.metrics_query import query_series

#: Graph.items is a lazy relationship and AsyncSession cannot load it outside an explicit
#: await (this raised a real sqlalchemy.exc.MissingGreenlet), so every read that reaches
#: the items must eager-load them.
WITH_ITEMS = selectinload(Graph.items)


def _plotted_value(point, function: str) -> float | None:
    """Which of the tier's aggregates this item plots.

    "last" is Zabbix's pie-only function; these charts are line-based, so it behaves like
    "avg" rather than silently plotting nothing.
    """
    if function == "min" and point.min_value is not None:
        return point.min_value
    if function == "max" and point.max_value is not None:
        return point.max_value
    return point.value


async def series_for_items(
    session: AsyncSession,
    settings: Settings,
    items,
    since: datetime | None,
) -> list[dict[str, Any]]:
    """One series per item, each with the tier it was served from.

    `resolution` travels with the data on purpose: a chart that silently switched from
    per-minute to per-day points would show a smoother line for the same metric and give
    no way to tell why.
    """
    out: list[dict[str, Any]] = []
    for item in items:
        tier, points = await query_series(session, settings, item.agent_id, item.metric, since)
        out.append(
            {
                "item_id": getattr(item, "id", None),
                "agent_id": item.agent_id,
                "metric": item.metric,
                "label": item.label,
                "color": item.color,
                "draw_style": item.draw_style,
                "axis_side": item.axis_side,
                "resolution": tier,
                "points": [
                    {"time": p.time.isoformat(), "value": _plotted_value(p, item.function)}
                    for p in points
                ],
            }
        )
    return out


async def load_graph(session: AsyncSession, graph_id: UUID | str) -> Graph | None:
    """A graph with its items eager-loaded, or None. Returning None rather than raising
    keeps this callable from the dashboard, which answers with a widget-level error message
    instead of an HTTP status."""
    from sqlalchemy import select

    return await session.scalar(select(Graph).options(WITH_ITEMS).where(Graph.id == graph_id))
