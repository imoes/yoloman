"""Software-compliance evaluation (gap #9): check each host's installed
packages against required/forbidden policies and alert on drift.

A rule carries a `required` and a `forbidden` list of *spec* strings. A spec is
a package name, optionally with a version constraint:

    nginx            # required: must be installed (any version)
    openssl>=3.0     # required: installed AND version >= 3.0
    log4j            # forbidden: must NOT be installed at all
    openssl<3.0      # forbidden: no version below 3.0 may be present

Evaluation reads `Agent.facts["installed_packages"]` (already collected by the
poller every 6h — no new collection) and produces a per-host ComplianceResult.
When a host transitions into violation, a NotifyEvent is dispatched so the
existing notification channels/escalation fire. Version comparison is
distro-aware (handles Debian epochs/revisions and RPM release tags), not PEP 440.
"""

from __future__ import annotations

import logging
import re
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import Agent, ComplianceResult, ComplianceRule
from bossman.services import notification
from bossman.services.compiler import affected_agent_ids

logger = logging.getLogger(__name__)

_SPEC_RE = re.compile(
    r"^\s*([A-Za-z0-9][A-Za-z0-9.+_-]*?)\s*(?:(<=|>=|==|=|<|>)\s*([A-Za-z0-9.:+~_-]+))?\s*$"
)


def parse_spec(spec: str) -> tuple[str, str | None, str | None]:
    """Split a spec into (name, op, version). op/version are None for a bare
    name. Raises ValueError on a malformed spec."""
    m = _SPEC_RE.match(spec or "")
    if not m or not m.group(1):
        raise ValueError(f"invalid package spec: {spec!r}")
    name, op, version = m.group(1), m.group(2), m.group(3)
    if op and not version:
        raise ValueError(f"spec {spec!r} has an operator but no version")
    if op == "=":
        op = "=="
    return name, op, version


def _split_version(v: str) -> list:
    """Normalize a distro version into comparable chunks. Strips a Debian
    epoch (`1:`) and a release/revision suffix (`-4ubuntu1`, RPM `-2.el9`),
    then alternates numeric and non-numeric tokens so `1.24.0` > `1.9` compares
    numerically. Numeric tokens compare as ints, text tokens as strings."""
    v = v.split(":", 1)[-1]          # drop epoch
    v = re.split(r"[-~]", v, 1)[0]   # drop revision/pre-release suffix
    tokens: list = []
    for part in re.findall(r"\d+|[A-Za-z]+", v):
        tokens.append((0, int(part)) if part.isdigit() else (1, part))
    return tokens


def _cmp_version(a: str, b: str) -> int:
    """Return -1/0/1 comparing distro versions a and b. Numeric ordering with a
    lexical fallback; a numeric token always sorts below a text token at the
    same position (so 1.0 < 1.0a is false — text ranks higher, matching the
    'release < snapshot' distro convention closely enough for policy checks)."""
    ta, tb = _split_version(a), _split_version(b)
    for x, y in zip(ta, tb):
        if x == y:
            continue
        # (0,int) vs (1,str): compare kind first (numeric<text), else value.
        if x[0] != y[0]:
            return -1 if x[0] < y[0] else 1
        return -1 if x[1] < y[1] else 1
    return (len(ta) > len(tb)) - (len(ta) < len(tb))


def _satisfies(installed_version: str, op: str, want: str) -> bool:
    c = _cmp_version(installed_version, want)
    return {
        "==": c == 0, "<": c < 0, "<=": c <= 0, ">": c > 0, ">=": c >= 0,
    }[op]


def evaluate_host(installed: list[dict], rule: ComplianceRule) -> list[dict]:
    """Return the list of violations for one host against one rule. Empty list =
    compliant. Each violation is {kind, package, detail}."""
    by_name: dict[str, str] = {}
    for pkg in installed or []:
        name = pkg.get("name") if isinstance(pkg, dict) else None
        if name:
            by_name[name] = pkg.get("version") or ""
    violations: list[dict] = []

    for spec in rule.required or []:
        try:
            name, op, want = parse_spec(spec)
        except ValueError:
            continue
        if name not in by_name:
            violations.append({"kind": "missing", "package": name, "detail": f"required {spec} not installed"})
        elif op and not _satisfies(by_name[name], op, want):
            violations.append({
                "kind": "version", "package": name,
                "detail": f"{name} {by_name[name]} does not satisfy {op}{want}",
            })

    for spec in rule.forbidden or []:
        try:
            name, op, want = parse_spec(spec)
        except ValueError:
            continue
        if name in by_name and (not op or _satisfies(by_name[name], op, want)):
            constraint = f"{op}{want}" if op else "any version"
            violations.append({
                "kind": "forbidden", "package": name,
                "detail": f"forbidden {name} {by_name[name]} present ({constraint})",
            })
    return violations


async def evaluate_rule(session: AsyncSession, settings: Settings, rule: ComplianceRule) -> dict:
    """Evaluate one rule across its scope, upsert a ComplianceResult per host,
    and dispatch an alert for hosts that newly went into violation. Returns a
    summary {rule, hosts, compliant, violating}."""
    agent_ids = await affected_agent_ids(
        session, rule.scope_type, ou_id=rule.ou_id, agent_id=rule.agent_id,
        host_group_id=rule.host_group_id, tenant_id=rule.tenant_id,
    )
    compliant = violating = 0
    for aid in agent_ids:
        agent = await session.get(Agent, aid)
        if agent is None:
            continue
        installed = (agent.facts or {}).get("installed_packages") or []
        violations = evaluate_host(installed, rule)
        status = "OK" if not violations else rule.severity

        prev = await session.scalar(
            select(ComplianceResult).where(
                ComplianceResult.rule_id == rule.id, ComplianceResult.agent_id == aid
            )
        )
        was_ok = prev is None or prev.status == "OK"
        if prev is None:
            prev = ComplianceResult(tenant_id=rule.tenant_id, rule_id=rule.id, agent_id=aid)
            session.add(prev)
        prev.status = status
        prev.violations = violations
        prev.evaluated_at = datetime.now(timezone.utc)

        if violations:
            violating += 1
            if was_ok:  # transition OK -> violation: alert once
                summary = "; ".join(v["detail"] for v in violations[:5])
                if len(violations) > 5:
                    summary += f" (+{len(violations) - 5} more)"
                await notification.dispatch(session, settings, notification.NotifyEvent(
                    agent_name=agent.name, service_name=f"Compliance: {rule.name}",
                    state=status, event="problem", output=summary,
                    agent_tags=agent.tags or {},
                ))
        else:
            compliant += 1
            if not was_ok:  # recovery
                await notification.dispatch(session, settings, notification.NotifyEvent(
                    agent_name=agent.name, service_name=f"Compliance: {rule.name}",
                    state="OK", event="recovery", output="back in compliance",
                    agent_tags=agent.tags or {},
                ))
    await session.commit()
    return {"rule": rule.name, "hosts": len(agent_ids), "compliant": compliant, "violating": violating}


async def evaluate_all(session: AsyncSession, settings: Settings, tenant_id=None) -> list[dict]:
    """Evaluate every enabled rule (optionally within one tenant)."""
    stmt = select(ComplianceRule).where(ComplianceRule.enabled.is_(True))
    if tenant_id is not None:
        stmt = stmt.where(ComplianceRule.tenant_id == tenant_id)
    rules = (await session.scalars(stmt)).all()
    return [await evaluate_rule(session, settings, r) for r in rules]


async def compliance_loop(
    session_factory: async_sessionmaker[AsyncSession], settings: Settings, stop_event
) -> None:
    """Periodically re-evaluate all compliance rules. Guarded by
    settings.compliance_enabled; interval settings.compliance_interval_seconds."""
    import asyncio

    if not settings.compliance_enabled:
        return
    interval = max(60, settings.compliance_interval_seconds)
    while not stop_event.is_set():
        try:
            async with session_factory() as session:
                await evaluate_all(session, settings)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            logger.exception("compliance evaluation cycle failed")
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval)
        except asyncio.TimeoutError:
            pass
