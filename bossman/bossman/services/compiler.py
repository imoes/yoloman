"""Policy/Orchestration compiler (Block L1): turns the OU tree + host
groups + orchestration plan links into a per-host **compiled desired
state** with a monotonic generation and a config hash.

This is the L-series analogue of services/templates.py's materialization:
inheritance is resolved down the OU tree (a link on an ancestor OU applies
to every host in its subtree) and across group membership, plans are
deduplicated + parameter-merged, and the result is hashed so a re-compile
only writes a new generation row when something actually changed.

Framework-free (no FastAPI import), like services/monitoring.py and
services/templates.py. Every function uses explicit select() queries
rather than lazy ORM relationship traversal — Block K11 found a real
sqlalchemy.exc.MissingGreenlet from touching a lazy relationship outside
an eager-load; explicit queries sidestep that class of bug entirely.

Scope note (L1): the monitoring section of the compiled state is derived
ONLY from the orchestration plans' `generated_monitoring` ("was
orchestriert wird, wird überwacht"). The existing CheckRule resolution
(services/monitoring.resolve_effective_rule) is deliberately NOT rerouted
through the OU tree here — that would change existing tested logic and is
a separate, explicitly-asked decision. No push happens in L1 either; this
only persists the desired state for inspection.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import (
    Agent,
    CompiledHostState,
    HostGroupMember,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OrchestrationPlanVersion,
    OUNode,
)


@dataclass
class ResolvedAssignment:
    """One orchestration plan effectively assigned to a host, after
    inheritance resolution + dedup + parameter merge."""

    plan_id: UUID
    plan_name: str
    plan_type: str
    version: int
    parameters: dict
    source: str  # human-readable provenance, e.g. "ou:/Germany/Munich/Prod"
    generated_monitoring: dict = field(default_factory=dict)
    generated_notifications: dict = field(default_factory=dict)


@dataclass
class CompiledState:
    generation: int
    changed: bool
    config_hash: str
    state: dict
    explain: dict


async def resolve_ou_ancestry(session: AsyncSession, ou_id: UUID | None) -> list[OUNode]:
    """The OU nodes from the tenant root down to (and including) `ou_id`,
    root first — the inheritance path. Cycle-safe (a corrupt parent chain
    can't loop forever). Returns [] for ou_id=None (host not placed)."""
    chain: list[OUNode] = []
    seen: set[UUID] = set()
    current = ou_id
    while current is not None and current not in seen:
        seen.add(current)
        node = await session.scalar(select(OUNode).where(OUNode.id == current))
        if node is None:
            break
        chain.append(node)
        current = node.parent_id
    chain.reverse()  # root first
    return chain


async def resolve_host_group_ids(session: AsyncSession, agent_id: UUID) -> set[UUID]:
    """Every HostGroup this host is a member of (many-to-many)."""
    rows = (
        await session.scalars(select(HostGroupMember.host_group_id).where(HostGroupMember.agent_id == agent_id))
    ).all()
    return set(rows)


async def _plan_version(
    session: AsyncSession, plan: OrchestrationPlan, requested_version: int | None
) -> OrchestrationPlanVersion | None:
    """The plan version a link resolves to: the link's pinned version, or
    the plan's current_version when the link leaves it NULL."""
    version = requested_version if requested_version is not None else plan.current_version
    return await session.scalar(
        select(OrchestrationPlanVersion).where(
            OrchestrationPlanVersion.plan_id == plan.id,
            OrchestrationPlanVersion.version == version,
        )
    )


async def resolve_orchestration_assignments(
    session: AsyncSession, agent: Agent
) -> list[ResolvedAssignment]:
    """Collect every enabled OrchestrationPlanLink that reaches this host —
    global links, links on any OU on the host's ancestry path, links on any
    group it belongs to, and host-direct links — then deduplicate by plan
    (the most specific / highest-priority link wins) and merge the link's
    parameters over the plan version's defaults.

    Precedence when two links target the same plan: higher `priority` wins;
    ties broken by scope specificity (host > group > ou > global) then by
    lower `link_order`. Matches the intent of the CheckRule precedence in
    services/monitoring.resolve_effective_rule (most specific wins)."""
    if agent.tenant_id is None:
        return []

    ancestry = await resolve_ou_ancestry(session, agent.ou_id)
    ancestry_ids = {n.id for n in ancestry}
    ou_paths = {n.id: n.path for n in ancestry}
    group_ids = await resolve_host_group_ids(session, agent.id)

    links = (
        await session.scalars(
            select(OrchestrationPlanLink).where(
                OrchestrationPlanLink.tenant_id == agent.tenant_id,
                OrchestrationPlanLink.enabled.is_(True),
            )
        )
    ).all()

    # scope specificity rank (higher = more specific), for tie-breaking.
    _SPECIFICITY = {"host": 3, "group": 2, "ou": 1, "global": 0, "label_selector": 0}

    @dataclass
    class _Candidate:
        link: OrchestrationPlanLink
        specificity: int
        source: str

    candidates: list[_Candidate] = []
    for link in links:
        if link.target_type == "global":
            candidates.append(_Candidate(link, _SPECIFICITY["global"], "global"))
        elif link.target_type == "ou" and link.ou_id in ancestry_ids:
            candidates.append(_Candidate(link, _SPECIFICITY["ou"], f"ou:{ou_paths.get(link.ou_id, link.ou_id)}"))
        elif link.target_type == "group" and link.host_group_id in group_ids:
            candidates.append(_Candidate(link, _SPECIFICITY["group"], f"group:{link.host_group_id}"))
        elif link.target_type == "host" and link.agent_id == agent.id:
            candidates.append(_Candidate(link, _SPECIFICITY["host"], "host"))
        # label_selector is defined in the schema but not evaluated in L1.

    # Winner per plan_id: highest priority, then most specific, then lowest
    # link_order (stable, deterministic — no reliance on row order).
    best: dict[UUID, _Candidate] = {}
    for cand in candidates:
        pid = cand.link.plan_id
        cur = best.get(pid)
        if cur is None or _better(cand, cur):
            best[pid] = cand

    assignments: list[ResolvedAssignment] = []
    for cand in best.values():
        plan = await session.scalar(
            select(OrchestrationPlan).where(
                OrchestrationPlan.id == cand.link.plan_id,
                OrchestrationPlan.enabled.is_(True),
                OrchestrationPlan.deleted_at.is_(None),
            )
        )
        if plan is None:
            continue
        version = await _plan_version(session, plan, cand.link.plan_version)
        if version is None:
            continue
        merged = {**version.default_parameters, **cand.link.parameters}
        assignments.append(
            ResolvedAssignment(
                plan_id=plan.id,
                plan_name=plan.name,
                plan_type=plan.plan_type,
                version=version.version,
                parameters=merged,
                source=cand.source,
                generated_monitoring=version.generated_monitoring or {},
                generated_notifications=version.generated_notifications or {},
            )
        )
    # Deterministic ordering of the output (by plan name).
    assignments.sort(key=lambda a: a.plan_name)
    return assignments


def _better(a, b) -> bool:
    """True if candidate `a` should beat `b` for the same plan."""
    if a.link.priority != b.link.priority:
        return a.link.priority > b.link.priority
    if a.specificity != b.specificity:
        return a.specificity > b.specificity
    if a.link.link_order != b.link.link_order:
        return a.link.link_order < b.link.link_order
    return False


def derive_generated_monitoring(assignments: list[ResolvedAssignment]) -> dict:
    """Union the `generated_monitoring` of every assigned plan into one
    monitoring section: a deduplicated, sorted list of checks and a merged
    threshold map (proposal §12). Later assignments (sorted by plan name)
    don't clobber earlier checks — checks are a set union; thresholds are a
    plain merge (a later plan naming the same threshold key wins, which is
    deterministic given the name-sorted order)."""
    checks: set[str] = set()
    thresholds: dict = {}
    notifications: set[str] = set()
    for a in assignments:
        gm = a.generated_monitoring or {}
        for c in gm.get("checks", []) or []:
            checks.add(c)
        for key, val in (gm.get("thresholds", {}) or {}).items():
            thresholds[key] = val
        for route in (a.generated_notifications or {}).get("routes", []) or []:
            notifications.add(route)
    return {
        "checks": sorted(checks),
        "thresholds": thresholds,
        "notifications": sorted(notifications),
    }


def _canonical_hash(state: dict) -> str:
    """sha256 of the canonical JSON (sorted keys, no whitespace jitter) so
    an identical desired state always hashes identically across compiles."""
    canonical = json.dumps(state, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


async def compile_host_desired_state(session: AsyncSession, agent_id: UUID) -> CompiledState | None:
    """Build the host's desired-state document, hash it, and — only if the
    hash differs from the current is_current row — retire that row and write
    a new generation. Returns None if the agent doesn't exist. Does not
    commit; the caller owns the transaction boundary (matching
    services/templates.py)."""
    agent = await session.scalar(select(Agent).where(Agent.id == agent_id))
    if agent is None:
        return None

    ancestry = await resolve_ou_ancestry(session, agent.ou_id)
    assignments = await resolve_orchestration_assignments(session, agent)
    monitoring = derive_generated_monitoring(assignments)

    state = {
        "host": {
            "name": agent.name,
            "ou": ancestry[-1].path if ancestry else None,
        },
        "monitoring": monitoring,
        "orchestration": {
            "roles": sorted(a.plan_name for a in assignments if a.plan_type == "role"),
            "plans": [
                {"name": a.plan_name, "version": a.version, "type": a.plan_type, "parameters": a.parameters}
                for a in assignments
            ],
        },
    }
    explain = {
        "ou_path": [n.path for n in ancestry],
        "assignments": [{"plan": a.plan_name, "source": a.source, "version": a.version} for a in assignments],
    }

    config_hash = _canonical_hash(state)

    current = await session.scalar(
        select(CompiledHostState).where(
            CompiledHostState.agent_id == agent_id, CompiledHostState.is_current.is_(True)
        )
    )
    if current is not None and current.config_hash == config_hash:
        return CompiledState(
            generation=current.generation, changed=False, config_hash=config_hash, state=state, explain=explain
        )

    next_generation = (current.generation + 1) if current is not None else 1
    if current is not None:
        current.is_current = False
        await session.flush()  # release the partial-unique-index slot before inserting the new current row

    row = CompiledHostState(
        tenant_id=agent.tenant_id,
        agent_id=agent_id,
        generation=next_generation,
        config_hash=config_hash,
        state=state,
        explain=explain,
        is_current=True,
    )
    session.add(row)
    await session.flush()
    return CompiledState(
        generation=next_generation, changed=True, config_hash=config_hash, state=state, explain=explain
    )


async def compile_tenant(session: AsyncSession, tenant_id: UUID) -> int:
    """Re-compile every host in a tenant (call after a plan/link/OU change,
    analogous to services/templates.materialize_template). Returns how many
    hosts' generations actually changed."""
    agent_ids = (await session.scalars(select(Agent.id).where(Agent.tenant_id == tenant_id))).all()
    changed = 0
    for aid in agent_ids:
        result = await compile_host_desired_state(session, aid)
        if result is not None and result.changed:
            changed += 1
    return changed
