"""Software-compliance API (gap #9): CRUD for required/forbidden-package rules,
run-now evaluation, and a per-host drift report.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.models import Agent, ComplianceResult, ComplianceRule
from bossman.db.session import get_session
from bossman.services import compliance

router = APIRouter()
DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


class ComplianceRuleIn(BaseModel):
    name: str
    enabled: bool = True
    scope_type: str  # global | host | group | ou
    agent_id: UUID | None = None
    host_group_id: UUID | None = None
    ou_id: UUID | None = None
    required: list[str] = []
    forbidden: list[str] = []
    severity: str = "CRIT"  # WARN | CRIT


class ComplianceRuleOut(BaseModel):
    id: UUID
    name: str
    enabled: bool
    scope_type: str
    agent_id: UUID | None
    host_group_id: UUID | None
    ou_id: UUID | None
    required: list[str]
    forbidden: list[str]
    severity: str
    created_at: datetime
    updated_at: datetime

    @classmethod
    def of(cls, r: ComplianceRule) -> "ComplianceRuleOut":
        return cls(
            id=r.id, name=r.name, enabled=r.enabled, scope_type=r.scope_type, agent_id=r.agent_id,
            host_group_id=r.host_group_id, ou_id=r.ou_id, required=r.required or [], forbidden=r.forbidden or [],
            severity=r.severity, created_at=r.created_at, updated_at=r.updated_at,
        )


class ComplianceResultOut(BaseModel):
    agent_id: UUID
    host_name: str
    status: str
    violations: list
    evaluated_at: datetime


def _validate(body: ComplianceRuleIn) -> None:
    if body.scope_type not in ("global", "host", "group", "ou"):
        raise HTTPException(422, "scope_type must be global|host|group|ou")
    if body.scope_type == "host" and not body.agent_id:
        raise HTTPException(422, "host scope needs agent_id")
    if body.scope_type == "group" and not body.host_group_id:
        raise HTTPException(422, "group scope needs host_group_id")
    if body.scope_type == "ou" and not body.ou_id:
        raise HTTPException(422, "ou scope needs ou_id")
    if body.severity not in ("WARN", "CRIT"):
        raise HTTPException(422, "severity must be WARN|CRIT")
    if not body.required and not body.forbidden:
        raise HTTPException(422, "a rule needs at least one required or forbidden package")
    for spec in [*body.required, *body.forbidden]:
        try:
            compliance.parse_spec(spec)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc


@router.get("/api/v1/compliance-rules", response_model=list[ComplianceRuleOut])
async def list_rules(session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    """Software-compliance rules: which packages must be present, which must not.

    A rule names `required` and `forbidden` package specs for a scope (global, host, group, ou), with
    a severity. A spec may carry a **version constraint** — `openssl>=3.0`, `log4j<2.17` — parsed and
    compared by version, not by string, so `2.9` is correctly older than `2.17`.

    These are the rules; `.../results` is what hosts actually hold.
    """
    rows = (await session.scalars(select(ComplianceRule).order_by(ComplianceRule.created_at.desc()))).all()
    return [ComplianceRuleOut.of(r) for r in rows]


@router.post("/api/v1/compliance-rules", response_model=ComplianceRuleOut)
async def create_rule(body: ComplianceRuleIn, session: AsyncSession = Depends(get_session),
                      identity: Identity = Depends(get_current_identity)):
    """Create a compliance rule.

    `required` and `forbidden` are lists of package specs, each `name` or `name<op>version` with op
    one of `<`, `<=`, `=`/`==`, `>=`, `>`. A spec without an operator means "any version" for
    required, and "at all" for forbidden.

    Evaluation is what the `compliance_loop` does on a cycle against each host's reported installed
    packages — creating a rule does not itself check anything. Use `.../evaluate` when you want the
    answer now.
    """
    _validate(body)
    r = ComplianceRule(
        tenant_id=DEFAULT_TENANT_ID, name=body.name, enabled=body.enabled, scope_type=body.scope_type,
        agent_id=body.agent_id, host_group_id=body.host_group_id, ou_id=body.ou_id,
        required=body.required, forbidden=body.forbidden, severity=body.severity, created_by=identity.name,
    )
    session.add(r)
    await session.commit()
    await session.refresh(r)
    return ComplianceRuleOut.of(r)


@router.put("/api/v1/compliance-rules/{rule_id}", response_model=ComplianceRuleOut)
async def update_rule(rule_id: UUID, body: ComplianceRuleIn, session: AsyncSession = Depends(get_session),
                      _i: Identity = Depends(get_current_identity)):
    """Replace a compliance rule. An omitted field is cleared, not kept.

    Existing results are not rewritten: they record what a host held when it was evaluated against
    the rule as it was then. The next evaluation replaces them. 404 for an unknown id.
    """
    r = await session.get(ComplianceRule, rule_id)
    if r is None:
        raise HTTPException(404, "no such rule")
    _validate(body)
    r.name, r.enabled, r.scope_type = body.name, body.enabled, body.scope_type
    r.agent_id, r.host_group_id, r.ou_id = body.agent_id, body.host_group_id, body.ou_id
    r.required, r.forbidden, r.severity = body.required, body.forbidden, body.severity
    await session.commit()
    await session.refresh(r)
    return ComplianceRuleOut.of(r)


@router.delete("/api/v1/compliance-rules/{rule_id}", status_code=204)
async def delete_rule(rule_id: UUID, session: AsyncSession = Depends(get_session),
                      _i: Identity = Depends(get_current_identity)):
    """Delete a compliance rule.

    Its results go with it — a drift report for a rule nobody can read is not evidence of anything.
    Disable the rule instead if the findings still matter.
    """
    r = await session.get(ComplianceRule, rule_id)
    if r is not None:
        await session.delete(r)
        await session.commit()


@router.post("/api/v1/compliance-rules/{rule_id}/evaluate")
async def evaluate_now(rule_id: UUID, session: AsyncSession = Depends(get_session),
                       settings: Settings = Depends(get_settings), _i: Identity = Depends(get_current_identity)):
    """Evaluate this rule immediately and return the result.

    Reads each in-scope host's **reported** installed packages rather than asking the hosts now, so
    the answer is as fresh as the last inventory poll — a host that has not checked in since an
    install still looks the way it did then. That is why the response carries the evaluation time.

    404 for an unknown rule. This is the same evaluation the periodic loop performs; running it by
    hand does not change the schedule.
    """
    r = await session.get(ComplianceRule, rule_id)
    if r is None:
        raise HTTPException(404, "no such rule")
    return await compliance.evaluate_rule(session, settings, r)


@router.get("/api/v1/compliance-rules/{rule_id}/results", response_model=list[ComplianceResultOut])
async def rule_results(rule_id: UUID, session: AsyncSession = Depends(get_session),
                       _i: Identity = Depends(get_current_identity)):
    """Per-host drift for this rule: who violates it, and with what.

    One entry per evaluated host, each listing the specs that failed — a missing required package, a
    version below the constraint, or a forbidden one found. A host with no entry is not silently
    compliant: it may simply not have been evaluated, which the evaluation time tells you.
    """
    rows = (await session.execute(
        select(ComplianceResult, Agent.name)
        .join(Agent, Agent.id == ComplianceResult.agent_id)
        .where(ComplianceResult.rule_id == rule_id)
        .order_by(ComplianceResult.status.desc(), Agent.name)
    )).all()
    return [
        ComplianceResultOut(agent_id=res.agent_id, host_name=name, status=res.status,
                            violations=res.violations or [], evaluated_at=res.evaluated_at)
        for res, name in rows
    ]
