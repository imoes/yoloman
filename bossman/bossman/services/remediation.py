"""Event-driven self-healing: run a remediation runbook when a check enters a
hard problem state.

collect_and_run is called by the poller right after notification dispatch, on the
same `_notify_event == "problem"` markers _upsert_service_state stamps. For each
such service it finds the RemediationPolicies that match (by check name + scope +
conditions), rate-limits per host (max_per_hour), and either runs the policy's
parameter-driven runbook (mode=auto) or logs a suggestion (mode=propose). Every
attempt is recorded in remediation_runs (audit + rate-limit source).
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import Agent, RemediationPolicy, RemediationRun, Runbook, Service
from bossman.services import nt_runbook, rule_conditions
from bossman.services.compiler import resolve_host_group_ids, resolve_ou_ancestry
from bossman.services.runbook_exec import execute_runbook

logger = logging.getLogger(__name__)


async def _agent_in_scope(session: AsyncSession, policy: RemediationPolicy, agent: Agent) -> bool:
    if policy.scope_type == "global":
        return True
    if policy.scope_type == "host":
        return policy.agent_id == agent.id
    if policy.scope_type == "group":
        return policy.host_group_id in set(await resolve_host_group_ids(session, agent.id))
    if policy.scope_type == "ou":
        ancestry = await resolve_ou_ancestry(session, agent.ou_id)
        return policy.ou_id in {n.id for n in ancestry}
    return False


async def matching_policies(session: AsyncSession, agent: Agent, service_name: str) -> list[RemediationPolicy]:
    """Enabled remediation policies that apply to this (host, check)."""
    pols = (await session.scalars(
        select(RemediationPolicy).where(
            RemediationPolicy.tenant_id == agent.tenant_id,
            RemediationPolicy.enabled.is_(True),
            RemediationPolicy.match_service_name.in_(["", service_name]),
        )
    )).all()
    out: list[RemediationPolicy] = []
    ctx = None
    for p in pols:
        if not await _agent_in_scope(session, p, agent):
            continue
        if p.conditions:
            if ctx is None:
                from bossman.services.check_assignments import build_match_context
                ctx = await build_match_context(session, agent)
            if not rule_conditions.matches(p.conditions, ctx):
                continue
        out.append(p)
    return out


async def _recent_runs(session: AsyncSession, policy_id: UUID, agent_id: UUID) -> int:
    since = datetime.now(timezone.utc) - timedelta(hours=1)
    return int(await session.scalar(
        select(func.count()).select_from(RemediationRun).where(
            RemediationRun.policy_id == policy_id, RemediationRun.agent_id == agent_id,
            RemediationRun.status == "ran", RemediationRun.at >= since,
        )
    ) or 0)


async def _run_policy(
    session: AsyncSession, settings: Settings, agent: Agent, service_name: str,
    policy: RemediationPolicy, client_factory, *, force: bool = False,
) -> dict[str, Any]:
    """Apply one remediation policy to one host: rate-limit, then run (auto) or
    propose. Records a RemediationRun and returns a small summary dict."""
    def log(status: str, detail: str) -> dict[str, Any]:
        session.add(RemediationRun(
            tenant_id=agent.tenant_id, policy_id=policy.id, agent_id=agent.id,
            service_name=service_name, runbook_name=policy.runbook_name, status=status, detail=detail[:2000],
        ))
        return {"policy": policy.name, "host": agent.name, "service": service_name,
                "runbook": policy.runbook_name, "status": status, "detail": detail}

    if not force and await _recent_runs(session, policy.id, agent.id) >= policy.max_per_hour:
        return log("rate_limited", f"{policy.max_per_hour}/h reached for this host")
    if policy.mode == "propose":
        return log("proposed", "mode=propose — suggestion only, not executed")
    if not agent.address:
        return log("failed", "host has no reachable address")

    rb = await session.scalar(select(Runbook).where(Runbook.name == policy.runbook_name))
    doc = nt_runbook.parse_data(rb.doc, source=f"runbook {policy.runbook_name!r}") if rb else None
    if not isinstance(doc, nt_runbook.Runbook):
        return log("failed", f"runbook {policy.runbook_name!r} missing or is a role")
    # Params carry the target (e.g. {"service": "nginx"}); the triggering check is
    # exposed so a generic playbook can act on it.
    request_vars = {**(policy.params or {}), "check_service": service_name, "check_host": agent.name}
    try:
        _, rr = await execute_runbook(
            session, agent, doc, settings=settings, client=client_factory(agent, settings),
            request_vars=request_vars, dry_run=False, requested_by=f"remediation:{policy.name}", commit=False,
        )
        ok = rr.get("ok", True) and not rr.get("aborted")
        return log("ran" if ok else "failed", "remediation runbook " + ("succeeded" if ok else "failed"))
    except Exception as exc:  # noqa: BLE001 — one bad remediation must not sink the cycle
        return log("failed", f"error: {str(exc)[:200]}")


async def run_remediations_for_service(
    session: AsyncSession, settings: Settings, agent: Agent, service_name: str, client_factory, *, force: bool = False,
) -> list[dict[str, Any]]:
    """Run every matching remediation policy for one (host, check). `force`
    bypasses the rate limit (manual/AI trigger)."""
    results = []
    for p in await matching_policies(session, agent, service_name):
        results.append(await _run_policy(session, settings, agent, service_name, p, client_factory, force=force))
    return results


async def collect_and_run(session: AsyncSession, settings: Settings, touched: list[Service], client_factory) -> int:
    """Poller hook: for every just-touched service that flipped INTO a hard
    problem (`_notify_event == "problem"`), run its matching remediation
    policies. Returns how many remediation runbooks actually ran."""
    ran = 0
    agents: dict[UUID, Agent] = {}
    for svc in touched:
        if getattr(svc, "_notify_event", None) != "problem":
            continue
        agent = agents.get(svc.agent_id)
        if agent is None:
            agent = await session.get(Agent, svc.agent_id)
            if agent is None:
                continue
            agents[svc.agent_id] = agent
        for res in await run_remediations_for_service(session, settings, agent, svc.name, client_factory):
            if res.get("status") == "ran":
                ran += 1
    return ran
