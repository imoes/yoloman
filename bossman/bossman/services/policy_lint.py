"""Policy linter — static analysis over the policy tree that answers "why
doesn't my policy apply?" and surfaces dead weight.

Findings (no LLM, pure logic over the same data the compiler resolves):
- a config policy linked to nothing (applies to no host),
- a config policy that sets no values,
- a threshold with neither warn nor crit,
- a condition whose tag / fact / variable / label key no host in the fleet
  currently has, so the rule can never match right now (the classic
  "I set it but nothing happened" trap).

Returns a flat list of findings the UI/MCP can show; nothing is changed.
"""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, CheckRule, ConfigPolicy, HostLabel, ScopeVars
from bossman.services.rule_conditions import flatten_facts


async def _fleet_keys(session: AsyncSession) -> dict[str, set[str]]:
    """The condition-dimension keys that actually exist across the fleet, so a
    condition referencing something else can be flagged as matching no host."""
    tags: set[str] = set()
    facts: set[str] = set()
    for a in (await session.scalars(select(Agent))).all():
        tags.update(str(k) for k in (a.tags or {}).keys())
        facts.update(flatten_facts(a.facts or {}).keys())
    variables: set[str] = set()
    for sv in (await session.scalars(select(ScopeVars))).all():
        variables.update(str(k) for k in (sv.vars or {}).keys())
    labels = {r.key for r in (await session.scalars(select(HostLabel))).all()}
    return {"host_tags": tags, "host_facts": facts, "host_vars": variables, "host_labels": labels, "service_labels": labels}


def _label_keys(groups: Any) -> set[str]:
    """Keys referenced inside a host/service label_groups condition."""
    out: set[str] = set()
    if not isinstance(groups, list):
        return out
    for g in groups:
        members = g[1] if isinstance(g, (list, tuple)) and len(g) == 2 else g
        if not isinstance(members, list):
            continue
        for m in members:
            if isinstance(m, (list, tuple)) and len(m) == 2:
                out.add(str(m[1]).split(":", 1)[0])
    return out


def _dead_condition_findings(conditions: dict, subject: str, fleet: dict[str, set[str]]) -> list[dict]:
    """Condition keys no host currently has → 'matches no host' findings."""
    findings: list[dict] = []
    for dim in ("host_tags", "host_facts", "host_vars"):
        for key in (conditions.get(dim) or {}).keys():
            if key not in fleet[dim]:
                findings.append({
                    "severity": "warning", "kind": "condition-matches-nothing", "subject": subject,
                    "detail": f"condition {dim}:{key} — no host currently has that {dim.replace('host_', '')} key",
                })
    for dim in ("host_label_groups", "service_label_groups"):
        vocab = fleet["host_labels" if dim == "host_label_groups" else "service_labels"]
        for key in _label_keys(conditions.get(dim)):
            if key not in vocab:
                findings.append({
                    "severity": "warning", "kind": "condition-matches-nothing", "subject": subject,
                    "detail": f"condition {dim}:{key} — no host currently has that label key",
                })
    return findings


async def lint_policies(session: AsyncSession) -> dict[str, Any]:
    """Analyse every config policy + enabled check rule; return {findings:[...]}."""
    fleet = await _fleet_keys(session)
    findings: list[dict] = []

    for cp in (await session.scalars(select(ConfigPolicy))).all():
        subject = f"config policy {cp.path}"
        linked = cp.scope_ou_id or cp.host_group_id or cp.site_id or cp.set_id
        if not linked:
            findings.append({"severity": "info", "kind": "unlinked", "subject": subject,
                             "detail": "not linked to any OU/group/site/policy — applies to no host"})
        if cp.type != "template_render" and not (cp.values or {}):
            findings.append({"severity": "warning", "kind": "empty-policy", "subject": subject,
                             "detail": "sets no values"})
        findings.extend(_dead_condition_findings(cp.conditions or {}, subject, fleet))

    for r in (await session.scalars(select(CheckRule).where(CheckRule.enabled.is_(True)))).all():
        subject = f"threshold {r.service_name} ({r.metric})"
        if r.warn_threshold is None and r.crit_threshold is None:
            findings.append({"severity": "info", "kind": "no-threshold", "subject": subject,
                             "detail": "neither warn nor crit set — the rule shadows inherited defaults with nothing"})
        findings.extend(_dead_condition_findings(r.conditions or {}, subject, fleet))

    order = {"error": 0, "warning": 1, "info": 2}
    findings.sort(key=lambda f: (order.get(f["severity"], 3), f["subject"]))
    return {"finding_count": len(findings), "findings": findings}
