"""Host error-signal gathering for the chat AI's root-cause analysis.

`gather_signals` collects a host's recent error evidence — journald errors,
error-ish lines from /var/log files, failed systemd services, and the latest
eBPF/service/resource metrics — for the chat `analyze_host` tool. The AI itself
correlates them and produces the Markdown + PlantUML analysis in the chat, so
this stays a pure, read-only gatherer (no LLM call here).
"""

from __future__ import annotations

import logging

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, Metric
from bossman.services.agent_client import AgentClientError

logger = logging.getLogger("bossman.error_analysis")

# Log files worth scanning for errors (kept small so the prompt stays focused).
KEY_LOGS = ("syslog", "messages", "kern.log", "daemon.log", "auth.log", "dmesg")
ERROR_MARKERS = ("error", "fail", "fatal", "panic", "denied", "refused", "segfault", "oom", "cannot", "critical", "traceback")
# Metrics that most often reveal a problem source.
METRIC_PREFIXES = ("service_", "container_", "vm_", "cpu_", "mem", "disk", "load", "net")


async def _tool(client, name, params):
    try:
        res = await client.call_tool(name, params)
        return res.get("data", res) if isinstance(res, dict) else {}
    except AgentClientError:
        return {}


async def gather_signals(session: AsyncSession, agent: Agent, client) -> dict:
    """Collect the raw error signals from the host (live) + stored metrics."""
    # journald errors (priority err and worse)
    journal = await _tool(client, "journal", {"priority": "3", "lines": 80})
    journal_errors = [f'{e.get("timestamp", "")} {e.get("unit", "")}: {e.get("message", "")}'
                      for e in (journal.get("entries") or []) if isinstance(e, dict)][:80]

    # error-ish lines from key /var/log files
    listing = await _tool(client, "logfiles", {"state": "list"})
    paths = {f.get("path") for f in (listing.get("files") or []) if isinstance(f, dict)}
    file_errors: dict[str, list[str]] = {}
    for base in KEY_LOGS:
        match = next((p for p in paths if p and p.split("/")[-1] == base), None)
        if not match:
            continue
        content = await _tool(client, "logfiles", {"state": "read", "path": match, "lines": 200})
        hits = [ln for ln in (content.get("lines") or []) if any(m in ln.lower() for m in ERROR_MARKERS)]
        if hits:
            file_errors[match] = hits[-30:]

    # failed systemd services (service_facts' data may be a list of units or a
    # dict {services|units: ...} depending on the module version)
    facts = await _tool(client, "service_facts", {})
    if isinstance(facts, list):
        services: object = facts
    else:
        services = facts.get("services") or facts.get("units") or []
    failed = []
    if isinstance(services, list):
        for s in services:
            if isinstance(s, dict) and (s.get("state") == "failed" or s.get("status") == "failed" or s.get("active") == "failed"):
                failed.append(s.get("name") or s.get("unit") or "?")
    elif isinstance(services, dict):
        for name, s in services.items():
            if isinstance(s, dict) and s.get("state") == "failed":
                failed.append(name)

    # latest stored metrics (eBPF/service/resource), most-recent per metric
    stmt = (
        select(Metric).where(Metric.agent_id == agent.id)
        .order_by(Metric.metric, Metric.time.desc()).distinct(Metric.metric)
    )
    metrics = []
    for m in (await session.scalars(stmt)).all():
        if any(m.metric.startswith(p) for p in METRIC_PREFIXES):
            label = m.labels.get("service") or m.labels.get("unit") or m.labels.get("name") or ""
            metrics.append(f'{m.metric}{("[" + label + "]") if label else ""}={round(m.value, 2)}')

    return {
        "host": agent.name,
        "journal_errors": journal_errors,
        "file_errors": file_errors,
        "failed_services": failed,
        "metrics": metrics[:120],
    }
