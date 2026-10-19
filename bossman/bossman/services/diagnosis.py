"""Why does a service not run — Bossman's side of the explainable diagnosis (docs/diagnosis.md, plan B8).

The AGENTS diagnose: `service_diagnose` applies deterministic rules to what the host measures and returns one
document (evidence, findings with certainty, timeline, gaps). Bossman asks for it, checks it again against the same
contract (services/diagnosis_contract.py — the fleet runs older agents too) and keeps it:

- a document that holds is stored with contract_status "ok";
- a document that does not hold is stored with contract_status "violation" and each reason — never dropped, never
  repaired, its certainty never raised. What the agent said stays visible next to why it does not count;
- an agent without the module is a named refusal (which host, which agent version), not an empty answer.

Nothing here changes a host. Remedies in a document are data; turning one into a proposal is B10.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import distinct, func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import DEFAULT_TENANT_ID, Agent, Diagnosis
from bossman.services import diagnosis_contract as contract
from bossman.services.agent_client import AgentClientError

TOOL = "service_diagnose"


class DiagnosisUnavailable(Exception):
    """The host cannot give a diagnosis — the message says which host and why; `status` is the HTTP answer
    (422 nothing named, 501 the agent has no module, 502 the agent failed or answered without a document)."""

    def __init__(self, message: str, status: int = 502):
        super().__init__(message)
        self.status = status


def _when(value: Any) -> datetime:
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            pass
    return datetime.now(timezone.utc)


def row_dict(row: Diagnosis, with_document: bool = True) -> dict[str, Any]:
    out: dict[str, Any] = {
        "id": str(row.id), "diagnosis_id": row.diagnosis_id, "host": row.host, "platform": row.platform,
        "target": {"kind": row.target_kind, "name": row.target_name}, "status": row.status, "summary": row.summary,
        "leading_rule": row.leading_rule, "leading_certainty": row.leading_certainty,
        "contract_status": row.contract_status, "contract_violations": row.contract_violations,
        "agent_version": row.agent_version, "collected_at": row.collected_at.isoformat(),
        "received_at": row.received_at.isoformat() if row.received_at else None,
    }
    if with_document:
        out["diagnosis"] = row.document
    return out


async def store(session: AsyncSession, agent: Agent, doc: dict[str, Any]) -> Diagnosis:
    """Check and keep one document. The same run (agent, diagnosis_id) arriving twice is kept once."""
    violations = contract.violations(doc)
    findings = doc.get("findings") if isinstance(doc.get("findings"), list) else []
    lead = findings[0] if findings and isinstance(findings[0], dict) else {}
    target = doc.get("target") if isinstance(doc.get("target"), dict) else {}
    values = {
        "tenant_id": agent.tenant_id or uuid.UUID(DEFAULT_TENANT_ID), "agent_id": agent.id,
        "diagnosis_id": str(doc.get("diagnosis_id") or uuid.uuid4()),
        "host": agent.name, "platform": str(doc.get("platform") or "unknown"),
        "target_kind": str(target.get("kind") or "service"), "target_name": str(target.get("name") or ""),
        "status": str(doc.get("status") or "unknown"), "summary": str(doc.get("summary") or ""),
        "leading_rule": lead.get("rule_id"), "leading_certainty": lead.get("certainty"),
        "contract_status": "violation" if violations else "ok", "contract_violations": violations,
        "agent_version": agent.agent_version, "document": doc, "collected_at": _when(doc.get("collected_at")),
    }
    await session.execute(insert(Diagnosis).values(**values)
                          .on_conflict_do_nothing(constraint="uq_diagnoses_agent_run"))
    await session.commit()
    return await session.scalar(select(Diagnosis).where(Diagnosis.agent_id == agent.id,
                                                        Diagnosis.diagnosis_id == values["diagnosis_id"]))


async def diagnose(session: AsyncSession, agent: Agent, client: Any, name: str) -> Diagnosis:
    """Ask the host why `name` does not run, check the answer, keep it."""
    if not name.strip():
        raise DiagnosisUnavailable("name the service to diagnose", status=422)
    try:
        res = await client.call_tool(TOOL, {"name": name})
    except AgentClientError as exc:
        if exc.status == 404:
            raise DiagnosisUnavailable(
                f"{agent.name} (agent {agent.agent_version or 'version unknown'}) has no {TOOL} module — "
                "update the agent to get a diagnosis", status=501) from exc
        raise DiagnosisUnavailable(f"{agent.name}: {exc}") from exc
    data = res.get("data") if isinstance(res, dict) else None
    doc = data.get("diagnosis") if isinstance(data, dict) else None
    if not isinstance(doc, dict):
        raise DiagnosisUnavailable(f"{agent.name} answered {TOOL} without a diagnosis document: {str(res)[:300]}")
    return await store(session, agent, doc)


UPDATE_TOOL = "update_diagnose"


async def diagnose_updates(session: AsyncSession, agent: Agent, client: Any) -> Diagnosis:
    """Ask the host why it is behind on updates (or why an update failed), check the answer, keep it. Same contract
    and the same store as the service diagnosis — the target is the updates of the host, not a named service."""
    try:
        res = await client.call_tool(UPDATE_TOOL, {})
    except AgentClientError as exc:
        if exc.status == 404:
            raise DiagnosisUnavailable(
                f"{agent.name} (agent {agent.agent_version or 'version unknown'}) has no {UPDATE_TOOL} module — "
                "update the agent to get an update diagnosis", status=501) from exc
        raise DiagnosisUnavailable(f"{agent.name}: {exc}") from exc
    data = res.get("data") if isinstance(res, dict) else None
    doc = data.get("diagnosis") if isinstance(data, dict) else None
    if not isinstance(doc, dict):
        raise DiagnosisUnavailable(f"{agent.name} answered {UPDATE_TOOL} without a diagnosis document: {str(res)[:300]}")
    return await store(session, agent, doc)


INCIDENTS_TOOL = "recent_incidents"


async def recent_incidents(agent: Agent, client: Any, *, kind: str = "", image: str = "",
                           within_minutes: int = 0, limit: int = 200) -> dict[str, Any]:
    """The host's recent PAST incidents for a timeline — the same ring the diagnosis cites (svc.recent_incident):
    on Linux the eBPF OOM-kill and fatal-signal rings, on Windows the ETW incident ring. This is a LIVE read, not a
    stored document: nothing is kept in Bossman — the ring is the host's own bounded history and an empty list after
    a restart is a named `ring_state`, not "no crashes". Read-only on the host. Returns the agent's data dict
    (source, ring_state, capacity, persistent, since, count, incidents[]) with host and agent_version added, so the
    caller can show "since when" alongside the incidents."""
    params: dict[str, Any] = {}
    if kind:
        params["kind"] = kind
    if image:
        params["image"] = image
    if within_minutes:
        params["within_minutes"] = within_minutes
    if limit:
        params["limit"] = limit
    try:
        res = await client.call_tool(INCIDENTS_TOOL, params)
    except AgentClientError as exc:
        if exc.status == 404:
            raise DiagnosisUnavailable(
                f"{agent.name} (agent {agent.agent_version or 'version unknown'}) has no {INCIDENTS_TOOL} module — "
                "update the agent to get the incident timeline", status=501) from exc
        raise DiagnosisUnavailable(f"{agent.name}: {exc}") from exc
    data = res.get("data") if isinstance(res, dict) else None
    if not isinstance(data, dict):
        raise DiagnosisUnavailable(f"{agent.name} answered {INCIDENTS_TOOL} without a ring: {str(res)[:300]}")
    return {"host": agent.name, "agent_version": agent.agent_version, **data}


async def recent(session: AsyncSession, agent: Agent, target: str = "", limit: int = 20) -> list[Diagnosis]:
    q = select(Diagnosis).where(Diagnosis.agent_id == agent.id)
    if target:
        q = q.where(Diagnosis.target_name == target)
    return list((await session.scalars(q.order_by(Diagnosis.collected_at.desc()).limit(limit))).all())


async def recent_all(session: AsyncSession, *, limit: int = 100, status: str = "", contract_status: str = "",
                     platform: str = "", q: str = "") -> list[Diagnosis]:
    """Recent diagnoses across the WHOLE fleet, newest first — the fleet-wide board, so stored diagnoses are findable
    without walking host by host. Optional filters: status (the diagnosed status, e.g. running/failed/behind),
    contract_status (ok/violation — to surface documents that did not hold), platform, and q (substring on host,
    service name or leading rule)."""
    stmt = select(Diagnosis).order_by(Diagnosis.collected_at.desc())
    if status:
        stmt = stmt.where(Diagnosis.status == status)
    if contract_status:
        stmt = stmt.where(Diagnosis.contract_status == contract_status)
    if platform:
        stmt = stmt.where(Diagnosis.platform == platform)
    if q:
        like = f"%{q}%"
        stmt = stmt.where(Diagnosis.host.ilike(like) | Diagnosis.target_name.ilike(like)
                          | Diagnosis.leading_rule.ilike(like))
    return list((await session.scalars(stmt.limit(max(1, min(limit, 500))))).all())


async def recurring(session: AsyncSession, *, limit: int = 20, since: datetime | None = None) -> list[dict[str, Any]]:
    """Which failure modes recur across the fleet — stored diagnoses grouped by leading rule, most frequent first.
    Each row: rule, how many times it was diagnosed, on how many distinct hosts, how many of those documents did not
    hold (violations), and when it was last seen. The pattern a root cause hides behind: "what keeps breaking?".
    `since` limits to recent history. Rows with no leading rule (nothing classified) are not a failure mode and are
    excluded."""
    violation = func.count().filter(Diagnosis.contract_status == "violation")
    stmt = (
        select(
            Diagnosis.leading_rule.label("rule"),
            func.count().label("count"),
            func.count(distinct(Diagnosis.agent_id)).label("hosts"),
            violation.label("violations"),
            func.max(Diagnosis.collected_at).label("last_seen"),
        )
        .where(Diagnosis.leading_rule.is_not(None))
        .group_by(Diagnosis.leading_rule)
        .order_by(func.count().desc(), func.max(Diagnosis.collected_at).desc())
        .limit(max(1, min(limit, 200)))
    )
    if since is not None:
        stmt = stmt.where(Diagnosis.collected_at >= since)
    rows = (await session.execute(stmt)).all()
    return [
        {"rule": r.rule, "count": r.count, "hosts": r.hosts, "violations": r.violations,
         "last_seen": r.last_seen.isoformat() if r.last_seen else None}
        for r in rows
    ]


async def related(session: AsyncSession, row: Diagnosis, limit: int = 20) -> list[Diagnosis]:
    """Other diagnoses of the SAME failure mode — the precedent for this one (the roadmap's RAG-cause lens): same
    leading rule, anywhere in the fleet or earlier, newest first, excluding this exact run. It answers "is this
    happening elsewhere / has it happened before?" — the recurrence a root cause hides behind. A diagnosis with no
    leading rule (nothing classified) has no failure mode to match, so it has no related set."""
    if not row.leading_rule:
        return []
    stmt = (select(Diagnosis)
            .where(Diagnosis.leading_rule == row.leading_rule, Diagnosis.id != row.id)
            .order_by(Diagnosis.collected_at.desc())
            .limit(max(1, min(limit, 100))))
    return list((await session.scalars(stmt)).all())
