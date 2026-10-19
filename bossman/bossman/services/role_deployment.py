"""Desired-state role/feature deployment and compliance worker."""

from __future__ import annotations

import asyncio
import copy
import hashlib
import json
import re
import shlex
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.api.config_templates import load_template_bodies
from bossman.api.package_wizard import _catalog, _family, _resolve_family
from bossman.db.models import (
    Agent,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OrchestrationPlanVersion,
    RoleDeployment,
    RoleDeploymentItem,
    RoleDeploymentTarget,
)
from bossman.services import nt_engine, nt_runbook
from bossman.services.agent_client import client_for
from bossman.services.compiler import affected_agent_ids, compile_host_desired_state
from bossman.services.runbook_exec import gather_magic_vars, resolve_run_variables

PILOT_THRESHOLD = 10
PILOT_STABILIZATION = timedelta(seconds=30)


def target_hash(agent_ids: list[UUID]) -> str:
    raw = ",".join(sorted(str(x) for x in agent_ids))
    return hashlib.sha256(raw.encode()).hexdigest()


def desired_hash(plan_id: UUID, version: int, parameters: dict) -> str:
    raw = json.dumps(
        {"plan_id": str(plan_id), "version": version, "parameters": parameters},
        sort_keys=True, separators=(",", ":"), default=str,
    )
    return hashlib.sha256(raw.encode()).hexdigest()


def deployment_preview_hash(agent_ids: list[UUID], items: list[dict], pilot_enabled: bool) -> str:
    """Lock everything an operator reviewed, not just scope membership."""
    raw = json.dumps({
        "target_hash": target_hash(agent_ids),
        "items": items,
        "pilot_enabled": pilot_enabled,
    }, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(raw.encode()).hexdigest()


async def resolve_scope(session: AsyncSession, tenant_id: UUID, scope_type: str, *,
                        agent_id=None, ou_id=None, host_group_id=None, site_id=None) -> list[UUID]:
    resolved = await affected_agent_ids(
        session, scope_type, tenant_id=tenant_id, agent_id=agent_id,
        ou_id=ou_id, host_group_id=host_group_id, site_id=site_id,
    )
    if not resolved:
        return []
    # affected_agent_ids intentionally serves older single-tenant call sites
    # and accepts a direct host id verbatim.  A deployment is tenant-owned, so
    # enforce the boundary here for every scope shape.
    allowed = (await session.scalars(select(Agent.id).where(
        Agent.id.in_(resolved), Agent.tenant_id == tenant_id,
    ))).all()
    return sorted(allowed, key=str)


async def sync_targets(session: AsyncSession, deployment: RoleDeployment) -> list[RoleDeploymentTarget]:
    """Reconcile dynamic scope membership into per-item host target rows."""
    ids = await resolve_scope(
        session, deployment.tenant_id, deployment.scope_type,
        agent_id=deployment.agent_id, ou_id=deployment.ou_id,
        host_group_id=deployment.host_group_id, site_id=deployment.site_id,
    )
    items = (await session.scalars(
        select(RoleDeploymentItem).where(RoleDeploymentItem.deployment_id == deployment.id)
        .order_by(RoleDeploymentItem.item_order)
    )).all()
    existing = (await session.scalars(
        select(RoleDeploymentTarget).where(RoleDeploymentTarget.deployment_id == deployment.id)
    )).all()
    by_key = {(t.item_id, t.agent_id): t for t in existing}
    wanted = {(it.id, aid) for it in items for aid in ids}
    pilot_id = ids[0] if deployment.pilot_enabled and len(ids) > 1 else None
    for item in items:
        fp = desired_hash(item.plan_id, item.plan_version, item.parameters or {})
        for aid in ids:
            row = by_key.get((item.id, aid))
            if row is None:
                row = RoleDeploymentTarget(
                    id=uuid4(), deployment_id=deployment.id, item_id=item.id, agent_id=aid,
                    phase="pilot" if aid == pilot_id else "main", state="pending", desired_hash=fp,
                )
                session.add(row)
                existing.append(row)
            elif row.state == "unmanaged" and not row.excluded:
                row.state = "pending"
                row.phase = "steady"
                row.desired_hash = fp
    for row in existing:
        if (row.item_id, row.agent_id) in wanted:
            continue
        if row.link_id:
            link = await session.get(OrchestrationPlanLink, row.link_id)
            if link is not None:
                await session.delete(link)
        row.link_id = None
        row.state = "unmanaged"
        row.last_error = None
    deployment.target_hash = target_hash(ids)
    await session.flush()
    return existing


def _plain_defaults(version: OrchestrationPlanVersion) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for name, value in (version.default_parameters or {}).items():
        if isinstance(value, dict) and "type" in value:
            if "default" in value:
                out[name] = value["default"]
        else:
            out[name] = value
    return out


def _detection_doc(doc: nt_runbook.Runbook) -> nt_runbook.Runbook:
    """Turn imperative service reloads into an idempotent compliance check.

    Installation runbooks legitimately restart a service after writing its
    configuration.  In check mode, however, ``state: restarted`` necessarily
    predicts a change forever.  Detection asks for the durable end state
    (running/enabled) so a healthy role can actually become compliant.
    """
    detected = copy.deepcopy(doc)

    def normalize(steps) -> list:
        kept = []
        for step in steps:
            # A command describes no state — it RUNS. In check mode the agent reports it changed=true as a
            # prediction (Ansible's convention), so a role with a "validate configuration" step could never be
            # compliant. Found by the package e2e: nginx stayed noncompliant forever with nothing to say why.
            # Detection checks the durable end state; the validation already ran during the apply.
            if step.module in ("command", "shell"):
                continue
            if step.module == "service" and step.args.get("state") in ("restarted", "reloaded"):
                step.args["state"] = "started"
            step.block = normalize(step.block)
            step.rescue = normalize(step.rescue)
            step.always = normalize(step.always)
            kept.append(step)
        return kept

    detected.steps = normalize(detected.steps)
    detected.handlers = normalize(detected.handlers)
    return detected


def is_write_gate_refusal(message: str | None) -> bool:
    """Does this error mean the host's write gate is closed (read-only agent)? The agent says
    `tool "package" is disabled (write=false)`; older wording was "read-only" / "write disabled"."""
    text = (message or "").lower()
    return any(marker in text for marker in ("write=false", "read-only", "write disabled"))


def drift_steps(result) -> list[str]:
    """The steps a check-mode run predicts would change — the named content of a drift.

    A SERVICE step that would still start its unit means the daemon is not running — that is the actionable fact,
    so it is named as such (measured right after an apply: 13 of 100 roles whose daemon did not stay up read as
    "still differs: Enable and restart X")."""
    out = []
    for s in result.steps:
        if not s.changed:
            continue
        if s.module == "service":
            unit = ((s.response or {}).get("data") or {}).get("unit") or s.name or "service"
            out.append(f"service not running: {unit}")
        else:
            out.append(s.name or s.module)
    return out or ["(unnamed step)"]


# systemd's own failure lines say THAT a unit failed, never why ("Job for x failed because the control process
# exited with error code"); the daemon's line before them does ("Error opening configuration file: server.conf",
# "unmet condition check ConditionPathExists=/etc/rsyncd.conf").
_UNIT_BOILERPLATE = re.compile(r"Failed with result|Main process exited|Control process exited|Failed to start|"
                               r"^Starting |^Started |^Stopping |^Stopped |Deactivated successfully|Consumed .* CPU|"
                               r"Scheduled restart job|Job for .* failed|See \"systemctl|^\s*$")
_UNIT_TELLING = re.compile(r"unmet condition|Assertion failed|[Ee]rror|ERROR|No such|not specified|[Ff]atal|[Pp]lease|"
                           r"[Cc]annot|[Cc]an't|[Uu]nable|refused|[Mm]issing|[Ii]nvalid|denied|not found|failed")


async def unit_reason(client, unit: str) -> str | None:
    """The journal line that says why `unit` is not running, or None. Read-only and best effort: a host that
    cannot answer leaves the reason as it was, it never turns a result into an error. Found by the Bossman-path
    e2e: 17 roles ended "service not running: rsync.service" while the journal named the missing file."""
    if not unit:
        return None
    try:
        res = await client.call_tool("command", {"cmd": f"journalctl -u {shlex.quote(unit)} -n 25 -o cat --no-pager"})
    except Exception:  # noqa: BLE001 — a reason we cannot read is no reason, not a failure
        return None
    data = (res.get("result") or res).get("data") or {}
    lines = [ln.strip() for ln in str(data.get("stdout") or "").splitlines()
             if ln.strip() and not _UNIT_BOILERPLATE.search(ln.strip())]
    telling = [ln for ln in lines if _UNIT_TELLING.search(ln)]
    pick = (telling or lines or [None])[-1]
    return pick[:300] if pick else None


def _service_unit(step) -> str:
    """The unit a service step acted on: the agent's response names it; a refused step only says it in its error
    ("systemd: restarting rsync.service: …")."""
    unit = ((step.response or {}).get("data") or {}).get("unit")
    if unit:
        return unit
    m = re.search(r"(?:restarting|starting|reloading|stopping|enabling) (\S+?):", step.error or "")
    return m.group(1) if m else ""


async def _with_unit_reasons(client, message: str, steps) -> str:
    """Append the journal's reason for every service step among `steps` (failed or still not running)."""
    reasons = []
    for s in steps:
        if s.module != "service":
            continue
        unit = _service_unit(s)
        why = await unit_reason(client, unit)
        if why:
            reasons.append(f"{unit}: {why}")
    return message + ("" if not reasons else " — journal: " + "; ".join(reasons))


def pilot_wait_reason(targets: list[RoleDeploymentTarget], now: datetime | None = None) -> str | None:
    """Why the main phase has not started yet, or None when it may run.

    The main phase waits until every pilot target is compliant AND has stayed so for PILOT_STABILIZATION
    since its apply. Shared by the worker (which obeys it) and the API (which shows it), so the reason the
    operator reads is the condition the worker evaluates — not a second description of it."""
    now = now or datetime.now(timezone.utc)
    pilots = [t for t in targets if t.phase == "pilot" and t.state != "unmanaged" and not t.excluded]
    if not pilots:
        return None
    if not all(t.state == "compliant" for t in pilots):
        return "waiting for the pilot host to become compliant"
    pending = [t for t in pilots if not t.applied_at or now - t.applied_at < PILOT_STABILIZATION]
    if pending:
        return f"waiting for the pilot host to stay compliant for {int(PILOT_STABILIZATION.total_seconds())} s"
    return None


def catalog_runtime(settings, agent: Agent, version: OrchestrationPlanVersion) -> tuple[dict, str | None]:
    req = version.requirements or {}
    package_name = req.get("catalog_name")
    if not package_name:
        return {}, None
    families = req.get("catalog_families")
    if families is None:
        entry = _catalog(settings).get(package_name)
        families = (entry or {}).get("families")
    if not families:
        return {}, f"catalog item {package_name!r} no longer exists"
    family = _family(agent.facts or {})
    if family == "unknown":
        # Not applicable FOR NOW: the worker retries not_applicable targets, so this resolves once the host reports.
        return {}, "the host has not reported its OS family yet — retried once its facts arrive"
    branch, meta = _resolve_family(families, family)
    if not meta.get("installable"):
        return {}, meta.get("reason") or f"not available on {family}"
    return {
        "_family": family,
        "_packages": branch.get("packages", []),
        "_dest": branch.get("config_path", ""),
        "_service": branch.get("service", ""),
        "_init": branch.get("init", ""),
        # Start at boot unless the catalog says the unit cannot be enabled (dnscache: a SysV script without runlevels).
        "_enable": branch.get("enable", True) is not False,
        "_features": branch.get("features", []),
        "_include_management_tools": bool(branch.get("include_management_tools")),
    }, None


def catalog_family_note(settings, agent: Agent, version: OrchestrationPlanVersion) -> str | None:
    """Why a catalog item counts as applicable on this host only by SUBSTITUTION, or None.

    `_resolve_family` installs a family's missing branch with another family's package names (`fallback`):
    often right (nginx is nginx everywhere), sometimes not (earlyoom is EPEL-only on AlmaLinux). The preview
    must say which hosts rest on that assumption, or "1/1 applicable" claims more than the catalog knows."""
    req = version.requirements or {}
    package_name = req.get("catalog_name")
    if not package_name:
        return None
    families = req.get("catalog_families")
    if families is None:
        families = (_catalog(settings).get(package_name) or {}).get("families")
    if not families:
        return None
    _branch, meta = _resolve_family(families, _family(agent.facts or {}))
    return meta.get("reason") or None if meta.get("family_match") == "fallback" else None


async def _evaluate_target(session: AsyncSession, settings, target: RoleDeploymentTarget,
                           *, apply: bool, client_factory=client_for) -> None:
    item = await session.get(RoleDeploymentItem, target.item_id)
    agent = await session.get(Agent, target.agent_id)
    if item is None or agent is None:
        target.state = "error"
        target.last_error = "deployment item or host no longer exists"
        return
    version = await session.scalar(select(OrchestrationPlanVersion).where(
        OrchestrationPlanVersion.plan_id == item.plan_id,
        OrchestrationPlanVersion.version == item.plan_version,
    ))
    plan = await session.get(OrchestrationPlan, item.plan_id)
    if version is None or plan is None:
        target.state = "error"
        target.last_error = "pinned artifact version no longer exists"
        return
    if not agent.address:
        target.state = "blocked"
        target.last_error = "host has no reachable address"
        return
    runtime, reason = catalog_runtime(settings, agent, version)
    if reason:
        target.state = "not_applicable"
        target.last_error = reason
        return
    try:
        doc = nt_runbook.parse_data({"name": f"deploy {plan.name}", "steps": version.steps})
        detection_doc = _detection_doc(doc)
        client = client_factory(agent, settings)
        magic = await gather_magic_vars(client, agent)
        # Runtime catalog values are derived from the target's OS and cannot be
        # overridden by API input (e.g. to install an arbitrary package).
        defaults = _plain_defaults(version)
        # `_role_defaults`: what the role's form offers when nobody changes it — the ROLE's (Debian) values. A
        # family template has its own; the engine lets those win for every value still equal to the role default
        # (nt_engine._config_template).
        # `_family_only`: fields only some families' files have (wizard_seed._add_family_fields) — a value set for
        # one of them on a host of another family is refused by the engine instead of vanishing.
        family_only = {name: spec["families"] for name, spec in (version.parameter_schema or {}).items()
                       if isinstance(spec, dict) and spec.get("families")}
        explicit = {**defaults, **(item.parameters or {}), **runtime, "_role_defaults": defaults,
                    "_family_only": family_only}
        variables = await resolve_run_variables(session, agent, settings, magic, explicit)
        templates = (version.requirements or {}).get("template_bodies")
        if templates is None:  # pre-snapshot versions remain executable
            templates = load_template_bodies(settings)
        target.state = "installing" if apply else target.state
        result = await nt_engine.run_runbook(
            doc if apply else detection_doc, client, variables, check_mode=not apply,
            templates=templates,
        )
        target.result = result.to_dict()
        target.last_error = None
        target.detected_at = datetime.now(timezone.utc)
        if not result.ok:
            # The FAILED step's reason — a skipped step may carry a note too (e.g. "installed, not configured"), and
            # reporting that one made a failure read as the skip.
            target.last_error = next((s.error for s in result.steps if s.status == "failed" and s.error),
                                     "role execution failed")
            target.last_error = await _with_unit_reasons(
                client, target.last_error, [s for s in result.steps if s.status == "failed"])
            # A host whose write gate is closed refuses the first write step with a 403 — reported by the engine
            # as a failed step, not raised. That is "blocked" (open the gate and it converges), not a role error.
            target.state = "blocked" if is_write_gate_refusal(target.last_error) else "error"
            return
        if not apply:
            target.state = "noncompliant" if result.changed else "compliant"
            if result.changed:
                # Drift must say WHAT drifted — a "noncompliant" with no reason sends the operator to the host
                # to find out what the detection already knew.
                target.last_error = "drift detected in: " + ", ".join(drift_steps(result))
            return

        # A successful apply is followed by a check-mode verification.  This is
        # the detection method for declarative catalog roles/features.
        verify = await nt_engine.run_runbook(
            detection_doc, client, variables, check_mode=True,
            templates=templates,
        )
        target.result = {"apply": result.to_dict(), "verify": verify.to_dict()}
        target.applied_at = datetime.now(timezone.utc)
        target.detected_at = target.applied_at
        target.correction_requested = False
        target.state = "compliant" if verify.ok and not verify.changed else ("noncompliant" if verify.ok else "error")
        if not verify.ok:
            target.last_error = next((s.error for s in verify.steps if s.status == "failed" and s.error),
                                     "verification failed")
        elif verify.changed:
            # Noncompliant right after a successful apply — say WHICH steps still differ, or the operator sees a
            # state with no reason behind it.
            target.last_error = await _with_unit_reasons(
                client, "still differs right after the apply: " + ", ".join(drift_steps(verify)),
                [s for s in verify.steps if s.changed])
        if target.state == "compliant" and target.link_id is None:
            link = OrchestrationPlanLink(
                id=uuid4(), tenant_id=agent.tenant_id, plan_id=item.plan_id,
                plan_version=item.plan_version, target_type="host", agent_id=agent.id,
                parameters={**(item.parameters or {}), **runtime}, priority=100, link_order=100,
                enabled=True, auto_apply=False, require_approval=False, status="active",
                created_by="role-deployment",
            )
            session.add(link)
            await session.flush()
            target.link_id = link.id
            await compile_host_desired_state(session, agent.id)
    except Exception as exc:  # noqa: BLE001 — state is the durable error report
        target.state = "blocked" if is_write_gate_refusal(str(exc)) else "error"
        target.last_error = str(exc)[:2000]


async def process_deployment_once(session: AsyncSession, settings, deployment_id: UUID | None = None,
                                  *, client_factory=client_for) -> int:
    stmt = select(RoleDeployment).where(RoleDeployment.status == "active")
    if deployment_id is not None:
        stmt = stmt.where(RoleDeployment.id == deployment_id)
    # One deployment may be triggered by the background loop and the manual
    # "Detect now" action at the same time.  Serialize at deployment level so
    # a host is never installed twice and two links cannot be created.
    deployments = (await session.scalars(stmt.with_for_update(skip_locked=True))).all()
    touched = 0
    for deployment in deployments:
        targets = await sync_targets(session, deployment)
        live = [t for t in targets if t.state != "unmanaged" and not t.excluded]
        pilot_ready = pilot_wait_reason(live) is None
        for target in live:
            if target.phase == "main" and not pilot_ready:
                continue
            should_apply = target.state in ("pending", "blocked", "not_applicable") or target.correction_requested
            if should_apply:
                await _evaluate_target(session, settings, target, apply=True, client_factory=client_factory)
                touched += 1
            elif target.state == "compliant":
                await _evaluate_target(session, settings, target, apply=False, client_factory=client_factory)
                touched += 1
        await session.commit()
    return touched


async def deployment_loop(session_factory: async_sessionmaker[AsyncSession], settings, stop_event,
                          *, client_factory=client_for) -> None:
    if not settings.role_deployment_enabled:
        return
    interval = max(10, settings.role_deployment_interval_seconds)
    while not stop_event.is_set():
        try:
            async with session_factory() as session:
                await process_deployment_once(session, settings, client_factory=client_factory)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 — background convergence is self-healing
            pass
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval)
        except (asyncio.TimeoutError, TimeoutError):
            pass


__all__ = [
    "PILOT_THRESHOLD", "catalog_family_note", "catalog_runtime", "drift_steps", "pilot_wait_reason", "deployment_preview_hash", "desired_hash", "target_hash",
    "resolve_scope", "sync_targets",
    "process_deployment_once", "deployment_loop",
]
