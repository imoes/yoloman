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


async def _execute_policy(
    session: AsyncSession, settings: Settings, agent: Agent, service_name: str,
    policy: RemediationPolicy, client_factory,
) -> tuple[str, str]:
    """Actually run one policy's remediation runbook on the host. Returns
    (status, detail). Execution NEVER happens automatically — only from an Apply
    (manual/AI), so there is no gate here beyond a reachable host."""
    if not agent.address:
        return "failed", "host has no reachable address"
    rb = await session.scalar(select(Runbook).where(Runbook.name == policy.runbook_name))
    doc = nt_runbook.parse_data(rb.doc, source=f"runbook {policy.runbook_name!r}") if rb else None
    if not isinstance(doc, nt_runbook.Runbook):
        return "failed", f"runbook {policy.runbook_name!r} missing or is a role"
    # Params carry the target (e.g. {"service": "nginx"}); the triggering check
    # is exposed so a generic playbook can act on it.
    request_vars = {**(policy.params or {}), "check_service": service_name, "check_host": agent.name}
    try:
        _, rr = await execute_runbook(
            session, agent, doc, settings=settings, client=client_factory(agent, settings),
            request_vars=request_vars, dry_run=False, requested_by=f"remediation:{policy.name}", commit=False,
        )
        ok = rr.get("ok", True) and not rr.get("aborted")
        return ("ran" if ok else "failed"), "remediation runbook " + ("succeeded" if ok else "failed")
    except Exception as exc:  # noqa: BLE001 — one bad remediation must not sink the cycle
        return "failed", f"error: {str(exc)[:200]}"


async def _has_open_proposal(session: AsyncSession, policy_id: UUID, agent_id: UUID, service_name: str) -> bool:
    """Is there already an un-applied proposal for this (policy, host, check)?
    Avoids re-proposing the same fix on every poll while the problem persists."""
    row = await session.scalar(
        select(RemediationRun.id).where(
            RemediationRun.policy_id == policy_id, RemediationRun.agent_id == agent_id,
            RemediationRun.service_name == service_name, RemediationRun.status == "pending",
        ).limit(1)
    )
    return row is not None


async def propose_for_service(session: AsyncSession, agent: Agent, service_name: str) -> list[dict[str, Any]]:
    """Event handling (automatic): record a PENDING remediation proposal for each
    matching policy — never executes. Deduped against an already-open proposal so
    a persistent problem doesn't spam the queue. Apply runs it."""
    out: list[dict[str, Any]] = []
    for p in await matching_policies(session, agent, service_name):
        if await _has_open_proposal(session, p.id, agent.id, service_name):
            continue
        run = RemediationRun(
            tenant_id=agent.tenant_id, policy_id=p.id, agent_id=agent.id, service_name=service_name,
            runbook_name=p.runbook_name, status="pending",
            detail=f"auto-detected on '{service_name}' — awaiting Apply",
        )
        session.add(run)
        out.append({"policy": p.name, "host": agent.name, "service": service_name, "runbook": p.runbook_name})
    return out


def _is_prod(agent: Agent) -> bool:
    """Best-effort 'is this a production host': criticality or an env tag."""
    if (agent.criticality or "").lower() in ("prod", "production", "critical"):
        return True
    return str((agent.tags or {}).get("env", "")).lower() in ("prod", "production")


async def _auto_allowed(
    session: AsyncSession, settings: Settings, policy: RemediationPolicy, agent: Agent,
    cycle_counts: dict,
) -> tuple[bool, str]:
    """The autonomy gate — every guardrail that must pass before a fix is applied
    unattended. Returns (allowed, reason). Any No leaves the proposal pending for a
    human."""
    if not settings.remediation_autonomy_enabled:
        return False, "autonomy kill-switch off"
    if not policy.enabled:
        return False, "policy disabled"
    if policy.autonomy != "auto_verify":
        return False, "policy not autonomous"
    if _is_prod(agent) and not policy.allow_prod:
        return False, "production host (allow_prod off)"
    if await _recent_runs(session, policy.id, agent.id) >= policy.max_per_hour:
        return False, "rate-limited (max_per_hour)"
    if cycle_counts.get(policy.id, 0) >= policy.max_blast_radius:
        return False, "blast-radius cap reached this cycle"
    return True, "ok"


async def _execute_runbook_by_name(
    session: AsyncSession, settings: Settings, agent: Agent, runbook_name: str,
    request_vars: dict, client_factory,
) -> tuple[bool, str]:
    """Run an arbitrary runbook (e.g. a compensating rollback) on a host. Best-effort."""
    if not agent.address:
        return False, "host has no reachable address"
    rb = await session.scalar(select(Runbook).where(Runbook.name == runbook_name))
    doc = nt_runbook.parse_data(rb.doc, source=f"runbook {runbook_name!r}") if rb else None
    if not isinstance(doc, nt_runbook.Runbook):
        return False, f"runbook {runbook_name!r} missing or is a role"
    try:
        _, rr = await execute_runbook(
            session, agent, doc, settings=settings, client=client_factory(agent, settings),
            request_vars=request_vars, dry_run=False, requested_by=f"remediation-rollback:{runbook_name}", commit=False)
        ok = rr.get("ok", True) and not rr.get("aborted")
        return ok, "rollback runbook " + ("succeeded" if ok else "failed")
    except Exception as exc:  # noqa: BLE001
        return False, f"rollback error: {str(exc)[:200]}"


async def apply_run(session: AsyncSession, settings: Settings, run: RemediationRun, client_factory) -> dict[str, Any]:
    """Execute a pending proposal now (the Apply button / AI). Updates the run's
    status to ran/failed."""
    policy = await session.get(RemediationPolicy, run.policy_id) if run.policy_id else None
    agent = await session.get(Agent, run.agent_id) if run.agent_id else None
    if policy is None or agent is None:
        run.status = "failed"
        run.detail = "policy or host no longer exists"
        return {"status": "failed", "detail": run.detail}
    status, detail = await _execute_policy(session, settings, agent, run.service_name, policy, client_factory)
    now = datetime.now(timezone.utc)
    run.status = status
    run.detail = detail
    run.at = now
    run.applied_at = now
    _set_verify_phase(run, policy, status, now)
    return {"status": status, "detail": detail, "phase": run.phase,
            "host": agent.name, "runbook": policy.runbook_name}


def _set_verify_phase(run: RemediationRun, policy: RemediationPolicy, status: str, now: datetime) -> None:
    """After an apply, move the run into its next lifecycle phase: a successful
    apply enters `verifying` (the poller re-checks it after verify_after_s) unless
    the policy disabled verify; a failed apply is terminal `failed`."""
    if status != "ran":
        run.phase = "failed"
        run.outcome = "apply_failed"
        return
    if getattr(policy, "verify", True):
        run.phase = "verifying"
        run.verify_due_at = now + timedelta(seconds=getattr(policy, "verify_after_s", 60) or 60)
    else:
        run.phase = "resolved"
        run.outcome = "applied (verify disabled)"


async def run_remediations_for_service(
    session: AsyncSession, settings: Settings, agent: Agent, service_name: str, client_factory, *, force: bool = False,
) -> list[dict[str, Any]]:
    """Run every matching policy for one (host, check) NOW and log each — the
    manual/AI direct trigger (there is no automatic execution path)."""
    results = []
    now = datetime.now(timezone.utc)
    for p in await matching_policies(session, agent, service_name):
        status, detail = await _execute_policy(session, settings, agent, service_name, p, client_factory)
        run = RemediationRun(
            tenant_id=agent.tenant_id, policy_id=p.id, agent_id=agent.id, service_name=service_name,
            runbook_name=p.runbook_name, status=status, detail=detail[:2000], applied_at=now, at=now,
        )
        _set_verify_phase(run, p, status, now)
        session.add(run)
        results.append({"policy": p.name, "host": agent.name, "service": service_name,
                        "runbook": p.runbook_name, "status": status, "phase": run.phase, "detail": detail})
    return results


async def collect_and_propose(session: AsyncSession, touched: list[Service]) -> int:
    """Poller hook (AUTOMATIC event handling): for every just-touched service that
    flipped INTO a hard problem, record a pending remediation proposal for each
    matching policy. Nothing is executed — an operator/AI applies it. Returns how
    many proposals were created."""
    proposed = 0
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
        proposed += len(await propose_for_service(session, agent, svc.name))
    return proposed


async def verify_due(session_factory, settings: Settings) -> int:
    """Closed-loop VERIFY step (poller hook). Picks up runs in phase `verifying`
    whose settle time has elapsed, re-checks the triggering service on the host,
    and closes the loop: recovered → `resolved`; still failing → `escalated`
    (notify a human via the existing notification engine). Best-effort per run —
    one bad verify never sinks the cycle. Returns how many runs were processed.

    Local imports avoid any import cycle at module load (poller imports this)."""
    from bossman.services.agent_client import client_for
    from bossman.services import notification
    from bossman.services.notification import NotifyEvent
    from bossman.services.monitoring import evaluate_assigned_checks

    now = datetime.now(timezone.utc)
    processed = 0
    async with session_factory() as session:
        rows = (await session.scalars(
            select(RemediationRun).where(
                RemediationRun.phase == "verifying", RemediationRun.verify_due_at <= now)
        )).all()
        for run in rows:
            agent = await session.get(Agent, run.agent_id) if run.agent_id else None
            if agent is None:
                run.phase = "failed"
                run.outcome = "host no longer exists"
                run.verified_at = now
                processed += 1
                continue
            # Best-effort targeted recheck so verify reflects the CURRENT state,
            # not a stale poll (assigned checks only; metric-threshold services are
            # refreshed by the poller and read below either way).
            if agent.address:
                try:
                    await evaluate_assigned_checks(session, agent, client_for(agent, settings), settings.checks_dir)
                except Exception:  # noqa: BLE001
                    logger.debug("verify recheck failed for %s", agent.name, exc_info=True)
            svc = await session.scalar(select(Service).where(
                Service.agent_id == run.agent_id, Service.name == run.service_name))
            state = svc.state if svc else None
            recovered = state == "OK"
            run.verified_at = now
            run.verify_state = state or "UNKNOWN"
            run.verify_ok = recovered
            if recovered:
                run.phase = "resolved"
                run.outcome = "recovered"
            else:
                run.phase = "escalated"
                run.outcome = f"no_recovery (still {state or 'UNKNOWN'})"
                # Optional compensating rollback runbook before we hand off to a human.
                policy = await session.get(RemediationPolicy, run.policy_id) if run.policy_id else None
                rb_name = getattr(policy, "rollback_runbook", None) if policy else None
                rolled = ""
                if rb_name and agent.address:
                    ok_rb, detail_rb = await _execute_runbook_by_name(
                        session, settings, agent, rb_name,
                        {"check_service": run.service_name, "check_host": agent.name}, client_for)
                    rolled = f" | rollback '{rb_name}': {'ok' if ok_rb else 'failed'} ({detail_rb})"
                    run.outcome += rolled
                try:
                    ev = NotifyEvent(
                        agent_name=agent.name, service_name=run.service_name,
                        state=state or "UNKNOWN", event="problem",
                        output=(f"Auto-remediation '{run.runbook_name}' did NOT recover "
                                f"'{run.service_name}' (still {state or 'UNKNOWN'}).{rolled} Manual attention needed."),
                        agent_tags=agent.tags or {})
                    await notification.dispatch(session, settings, ev)
                except Exception:  # noqa: BLE001
                    logger.warning("remediation escalation dispatch failed for %s", agent.name, exc_info=True)
            processed += 1
        if processed:
            await session.commit()
    if processed:
        logger.info("remediation verify: processed %d run(s)", processed)
    return processed


async def auto_apply_due(session_factory, settings: Settings) -> int:
    """Autonomous apply step (poller hook, Phase 2). Pulls PENDING proposals whose
    policy is `auto_verify`, runs each through the guardrail gate, and — only when
    every guardrail passes — applies it (which enters `verifying`, so the Phase-1
    verify closes the loop). Anything that fails a guardrail stays pending for a
    human. Gated overall by the autonomy kill-switch. Returns how many were applied.

    Local import avoids an import cycle at module load (poller imports this)."""
    if not settings.remediation_autonomy_enabled:
        return 0
    from bossman.services.agent_client import client_for

    applied = 0
    cycle_counts: dict = {}
    async with session_factory() as session:
        rows = (await session.scalars(
            select(RemediationRun).where(
                RemediationRun.status == "pending", RemediationRun.phase == "proposed")
            .order_by(RemediationRun.at.asc())
        )).all()
        for run in rows:
            policy = await session.get(RemediationPolicy, run.policy_id) if run.policy_id else None
            agent = await session.get(Agent, run.agent_id) if run.agent_id else None
            if policy is None or agent is None:
                continue
            allowed, reason = await _auto_allowed(session, settings, policy, agent, cycle_counts)
            if not allowed:
                logger.debug("auto-apply skipped %s/%s: %s", agent.name, run.service_name, reason)
                continue
            cycle_counts[policy.id] = cycle_counts.get(policy.id, 0) + 1
            await apply_run(session, settings, run, client_for)
            run.detail = f"[auto] {run.detail or ''}".strip()
            applied += 1
        if applied:
            await session.commit()
    if applied:
        logger.info("remediation auto-apply: applied %d proposal(s)", applied)
    return applied
