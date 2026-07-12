"""AI error-source analysis (roadmap block 3).

Correlates a host's recent error signals — journald errors, error-ish lines
from /var/log files, failed systemd services, and the latest eBPF/service
metrics — and asks the LLM to name the likely error source(s), the evidence,
and a recommended fix. Read-only: it only gathers and reasons, never changes
the host.
"""

from __future__ import annotations

import json
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

FINDINGS_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string", "description": "One-paragraph overall assessment of the host's health."},
        "findings": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "component": {"type": "string", "description": "The service/unit/subsystem implicated."},
                    "severity": {"type": "string", "enum": ["critical", "high", "medium", "low", "info"]},
                    "evidence": {"type": "string", "description": "The specific log lines / metrics that point to this."},
                    "recommendation": {"type": "string"},
                },
                "required": ["title", "component", "severity", "evidence", "recommendation"],
            },
        },
    },
    "required": ["summary", "findings"],
}


def _lines(entry_list, key: str) -> list[str]:
    return [str(e.get(key, "")) for e in (entry_list or []) if isinstance(e, dict)]


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
        "journal_errors": journal_errors,
        "file_errors": file_errors,
        "failed_services": failed,
        "metrics": metrics[:120],
    }


def _prompt(agent: Agent, signals: dict) -> list[dict[str, str]]:
    system = (
        "You are a senior SRE doing root-cause analysis on a single Linux host. You are given the "
        "host's recent journald errors, error-ish lines from /var/log, failed systemd services, and "
        "the latest resource/eBPF/service metrics. Correlate them: find the LIKELY SOURCE(S) of "
        "errors, not just symptoms. For each finding give the implicated component, a severity, the "
        "concrete evidence (cite the actual log line or metric), and a concrete recommendation. If the "
        "host looks healthy, say so with an empty findings list. Do not invent evidence."
    )
    parts = [f"HOST: {agent.name}"]
    if signals["failed_services"]:
        parts.append("FAILED SERVICES:\n" + "\n".join(signals["failed_services"]))
    if signals["journal_errors"]:
        parts.append("JOURNALD ERRORS (priority err+):\n" + "\n".join(signals["journal_errors"]))
    for path, lines in signals["file_errors"].items():
        parts.append(f"{path} (error lines):\n" + "\n".join(lines))
    if signals["metrics"]:
        parts.append("LATEST METRICS (eBPF/service/resource):\n" + "\n".join(signals["metrics"]))
    if len(parts) == 1:
        parts.append("No errors, failed services, or notable metrics were found.")
    return [{"role": "system", "content": system}, {"role": "user", "content": "\n\n".join(parts)}]


async def analyze_host(session: AsyncSession, agent: Agent, client, chat) -> dict:
    signals = await gather_signals(session, agent, client)
    messages = _prompt(agent, signals)
    report = await chat.complete_json(messages, FINDINGS_SCHEMA, "error_analysis", max_tokens=3000)
    return {
        "agent_id": str(agent.id),
        "host": agent.name,
        "signals": {
            "journal_errors": len(signals["journal_errors"]),
            "file_errors": {p: len(v) for p, v in signals["file_errors"].items()},
            "failed_services": signals["failed_services"],
            "metrics": len(signals["metrics"]),
        },
        "summary": report.get("summary", ""),
        "findings": report.get("findings", []),
    }
