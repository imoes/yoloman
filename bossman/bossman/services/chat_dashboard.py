"""Block W2 — the generative dashboard designer (like CentralStation's).

Asks the configured AI to DESIGN a dashboard: it may call the fleet tools to
get real data, then emits a JSON array of inline-data widget specs
([{widget_type, title, data, gs_w, gs_h}]). We parse it robustly, validate
each spec against the allow-list of renderable widget types, clamp sizes, and
return the list — which the router persists per user and the UI renders with
the shared widget component.
"""

from __future__ import annotations

import json
import re
from typing import Any

from bossman.services.chat_agent import backend_is_agentic, run_agentic
from bossman.services.chat_prompt import WIDGET_VOCAB

# The widget types the UI can render (kept in sync with dashboard.model.ts).
ALLOWED_WIDGETS = {
    "donut", "gauge", "stat", "timeseries", "bar", "table",
    "status_tiles", "progress", "ai_summary", "war_room", "log", "callout", "plan_graph",
}

MAX_WIDGETS = 12

DESIGN_PROMPT = f"""\
You are designing an operations dashboard for a fleet-management app. The user
gives you a short intent (e.g. "show me fleet health") — it is YOUR job to
decide, autonomously, which widgets best answer it and how big each should be.
Do not ask the user anything back.

First use the available tools to fetch REAL fleet data (e.g. list_hosts,
fleet_health). Then design 3–8 widgets that together tell the story.

Output ONLY a JSON array (no prose, no markdown fences) of widget specs:
[{{"widget_type": "...", "title": "...", "data": {{ ... }}, "gs_w": 4, "gs_h": 4}}]

The `data` object MUST use the exact shape for its widget_type:
{WIDGET_VOCAB}

Rules:
- Fill `data` with the REAL data you gathered from tools — never invent counts.
- Choose widgets that fit the intent: lead with a few compact KPI tiles
  (stat/gauge, gs_w 2–3, gs_h 2), then wider charts (donut/bar, gs_w 4–6,
  gs_h 4), then a full-width table/ai_summary (gs_w 12, gs_h 4–6) if useful.
- Size each widget by importance: gs_w 2–12 columns, gs_h 2–8 rows.
- You do NOT need to set x/y positions — the app arranges the widgets into a
  tidy 12-column grid in the order you list them, using your sizes. So ORDER
  them the way they should read: overview KPIs first, details last.
- 12 columns total per row; keep individual widgets ≤ 12 wide."""


def _parse_specs(text: str) -> list[dict[str, Any]]:
    """Pull a JSON array of specs out of the model's text (tolerating a
    ```json fence or surrounding prose)."""
    text = (text or "").strip()
    # Strip a code fence if present.
    fence = re.search(r"```(?:json)?\s*([\s\S]*?)```", text)
    if fence:
        text = fence.group(1).strip()
    # Find the outermost JSON array.
    start, end = text.find("["), text.rfind("]")
    if start == -1 or end == -1 or end <= start:
        return []
    try:
        parsed = json.loads(text[start : end + 1])
    except ValueError:
        return []
    return parsed if isinstance(parsed, list) else []


def _clean_spec(spec: dict[str, Any]) -> dict[str, Any] | None:
    wt = spec.get("widget_type")
    if wt not in ALLOWED_WIDGETS:
        return None
    return {
        "widget_type": wt,
        "title": str(spec.get("title") or wt),
        "data": spec.get("data") if isinstance(spec.get("data"), dict) else {},
        "gs_w": max(2, min(12, int(spec.get("gs_w") or 4))),
        "gs_h": max(2, min(8, int(spec.get("gs_h") or 4))),
    }


def _pack_layout(specs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Assign gs_x/gs_y by shelf-packing the widgets left-to-right in a
    12-column grid, in the order the model listed them, using each widget's
    chosen size. Deterministic, overlap-free layout — so "position it correctly
    in the grid" doesn't depend on the model getting x/y right (it rarely does).
    A widget wider than the remaining row wraps to a new shelf."""
    x = 0
    y = 0
    row_h = 0
    for s in specs:
        w = min(12, s["gs_w"])
        h = s["gs_h"]
        if x + w > 12:
            x = 0
            y += row_h
            row_h = 0
        s["gs_x"] = x
        s["gs_y"] = y
        x += w
        row_h = max(row_h, h)
    return specs


async def generate_dashboard(backend, executor, user_prompt: str) -> list[dict[str, Any]]:
    """Run the AI to design a dashboard and return the validated widget specs."""
    messages = [
        {"role": "system", "content": DESIGN_PROMPT},
        {"role": "user", "content": user_prompt.strip() or "Design a fleet status overview dashboard."},
    ]
    parts: list[str] = []
    if backend_is_agentic(backend):
        async for ev in run_agentic(backend, messages, executor):
            if ev.get("type") == "delta" and ev.get("text"):
                parts.append(ev["text"])
    else:
        async for ev in backend.stream(messages):
            if ev.get("type") == "delta" and ev.get("text"):
                parts.append(ev["text"])
    specs = _parse_specs("".join(parts))
    cleaned = [c for s in specs if isinstance(s, dict) and (c := _clean_spec(s))]
    return _pack_layout(cleaned[:MAX_WIDGETS])
