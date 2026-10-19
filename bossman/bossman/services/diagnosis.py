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

from sqlalchemy import select
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


async def recent(session: AsyncSession, agent: Agent, target: str = "", limit: int = 20) -> list[Diagnosis]:
    q = select(Diagnosis).where(Diagnosis.agent_id == agent.id)
    if target:
        q = q.where(Diagnosis.target_name == target)
    return list((await session.scalars(q.order_by(Diagnosis.collected_at.desc()).limit(limit))).all())
