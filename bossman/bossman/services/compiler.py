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

from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import (
    SYSTEM_SETTINGS_ID,
    Agent,
    CheckRule,
    CompiledHostState,
    HostGroupMember,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OrchestrationPlanVersion,
    OUNode,
    SystemSettings,
)
from bossman.services import gpo


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
    root first — the inheritance path. Block L3a: one ltree ancestor query
    (`ancestor.ltree_path @> target.ltree_path`) instead of walking parent_id,
    ordered by depth (number of path labels). Returns [] for ou_id=None
    (host not placed)."""
    if ou_id is None:
        return []
    target = await session.scalar(select(OUNode).where(OUNode.id == ou_id, OUNode.deleted_at.is_(None)))
    if target is None:
        return []
    rows = (
        await session.scalars(
            select(OUNode)
            .where(
                OUNode.tenant_id == target.tenant_id,
                OUNode.deleted_at.is_(None),
                text("ou_nodes.ltree_path @> :p ::ltree"),
            )
            .params(p=str(target.ltree_path))
        )
    ).all()
    # root first: fewer labels = shallower. nlevel == number of dots + 1.
    return sorted(rows, key=lambda n: str(n.ltree_path).count("."))


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


async def is_yolo_mode(session: AsyncSession) -> bool:
    """The global L2 override switch ("YOLO-MAN" — You Only Look Once):
    when true, api/orchestration.py's create_plan_link makes every new
    link active immediately, bypassing its own require_approval/auto_apply
    values. Deliberately human-only to set (REST API, never the MCP write
    tool) — see db.models.SystemSettings."""
    settings = await session.get(SystemSettings, UUID(SYSTEM_SETTINGS_ID))
    return settings.yolo_mode if settings is not None else False


async def affected_agent_ids(
    session: AsyncSession,
    target_type: str,
    *,
    ou_id: UUID | None = None,
    agent_id: UUID | None = None,
    host_group_id: UUID | None = None,
    tenant_id: UUID | None = None,
) -> list[UUID]:
    """Which hosts a given scope (as used by an OrchestrationPlanLink)
    touches — shared by the REST link create/delete/approve endpoints (to
    know which hosts to recompile) and by preview_plan_link (to report
    blast radius before a link is even created)."""
    if target_type == "global":
        if tenant_id is None:
            return []
        rows = (await session.scalars(select(Agent.id).where(Agent.tenant_id == tenant_id))).all()
        return list(rows)
    if target_type == "host":
        return [agent_id] if agent_id else []
    if target_type == "group":
        rows = (await session.scalars(select(HostGroupMember.agent_id).where(HostGroupMember.host_group_id == host_group_id))).all()
        return list(rows)
    if target_type == "ou":
        node = await session.get(OUNode, ou_id) if ou_id else None
        if node is None:
            return []
        # ltree descendant match (`descendant <@ ancestor`) — correct subtree
        # semantics, unlike a path prefix LIKE which would also match a
        # sibling like /Germany2 under /Germany.
        subtree = (
            await session.scalars(
                select(OUNode.id).where(
                    OUNode.tenant_id == node.tenant_id, text("ou_nodes.ltree_path <@ :p ::ltree")
                ).params(p=str(node.ltree_path))
            )
        ).all()
        rows = (await session.scalars(select(Agent.id).where(Agent.ou_id.in_(subtree)))).all()
        return list(rows)
    return []


async def resolve_orchestration_assignments(
    session: AsyncSession, agent: Agent, extra_candidate_link: OrchestrationPlanLink | None = None
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
    ancestry_depth = {n.id: i for i, n in enumerate(ancestry)}
    ou_paths = {n.id: n.path for n in ancestry}
    group_ids = await resolve_host_group_ids(session, agent.id)
    # Deepest OU on the path that blocks inheritance (GPO Block Inheritance).
    blocked_level: int | None = None
    for n in ancestry:
        if n.block_inheritance:
            blocked_level = gpo.LEVEL_OU_BASE + ancestry_depth[n.id]

    links = (
        await session.scalars(
            select(OrchestrationPlanLink).where(
                OrchestrationPlanLink.tenant_id == agent.tenant_id,
                OrchestrationPlanLink.enabled.is_(True),
                # Block L2: a pending_approval link has no effect until a
                # human approves it; a rejected one never will.
                OrchestrationPlanLink.status == "active",
            )
        )
    ).all()
    if extra_candidate_link is not None:
        # preview_plan_link's not-yet-persisted "what if this link existed"
        # candidate — evaluated as if it were active, since previewing a
        # pending-approval link's would-be effect is the whole point.
        links = [*links, extra_candidate_link]

    # Group candidate links per plan; the GPO winner per plan is the
    # effective assignment (Block L3a: enforced/block_inheritance/level via
    # services/gpo.resolve_winner, shared with monitoring). `source` records
    # provenance for the explain plan; `priority` rides the subrank tiebreak
    # (higher priority wins within a level).
    per_plan: dict[UUID, list[gpo.GpoCandidate]] = {}
    sources: dict[int, str] = {}
    for link in links:
        if link.target_type == "global":
            level, source = gpo.LEVEL_GLOBAL, "global"
        elif link.target_type == "ou" and link.ou_id in ancestry_depth:
            level = gpo.LEVEL_OU_BASE + ancestry_depth[link.ou_id]
            source = f"ou:{ou_paths.get(link.ou_id, link.ou_id)}"
        elif link.target_type == "group" and link.host_group_id in group_ids:
            level, source = gpo.LEVEL_GROUP, f"group:{link.host_group_id}"
        elif link.target_type == "host" and link.agent_id == agent.id:
            level, source = gpo.LEVEL_HOST, "host"
        else:
            continue  # label_selector / non-matching scope — not evaluated here
        sources[id(link)] = source
        per_plan.setdefault(link.plan_id, []).append(
            gpo.GpoCandidate(
                obj=link,
                # None-safe for un-flushed links (e.g. preview's synthetic candidate).
                enforced=bool(link.enforced),
                level=level,
                link_order=link.link_order if link.link_order is not None else 100,
                created_ts=link.created_at.timestamp() if link.created_at else 0.0,
                subrank=link.priority if link.priority is not None else 100,
            )
        )

    assignments: list[ResolvedAssignment] = []
    for plan_id, cands in per_plan.items():
        winner = gpo.resolve_winner(cands, blocked_level)
        if winner is None:
            continue
        plan = await session.scalar(
            select(OrchestrationPlan).where(
                OrchestrationPlan.id == plan_id,
                OrchestrationPlan.enabled.is_(True),
                OrchestrationPlan.deleted_at.is_(None),
            )
        )
        if plan is None:
            continue
        version = await _plan_version(session, plan, winner.plan_version)
        if version is None:
            continue
        merged = {**version.default_parameters, **winner.parameters}
        assignments.append(
            ResolvedAssignment(
                plan_id=plan.id,
                plan_name=plan.name,
                plan_type=plan.plan_type,
                version=version.version,
                parameters=merged,
                source=sources[id(winner)],
                generated_monitoring=version.generated_monitoring or {},
                generated_notifications=version.generated_notifications or {},
            )
        )
    # Deterministic ordering of the output (by plan name).
    assignments.sort(key=lambda a: a.plan_name)
    return assignments


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


async def resolve_host_thresholds(
    session: AsyncSession, agent: Agent, host_ou_ancestry: list[OUNode]
) -> dict[str, dict]:
    """The GPO-resolved check-rule thresholds a host must ENFORCE, keyed by
    metric (Block L4-behavioral). For every metric that has an enabled
    check_rule anywhere, pick the single governing rule for this host via the
    same full GPO precedence monitoring uses (host > OU(deep→shallow) > group >
    global, with enforced/block_inheritance) — `resolve_effective_rule`, the
    one shared resolver — and emit `{metric: {warn, crit, comparison,
    service_name}}`.

    This is what makes the OU/GPO console's thresholds actually reach the host:
    the compiled desired state now carries the human-set thresholds, not just
    plan-authored defaults. Resolution is label-agnostic (label_value=None), so
    a per-mount (disk) rule folds to one whole-metric override for the agent's
    built-in check; label-specific rules are left to Bossman-side evaluation
    for now (documented first cut)."""
    # Imported here (not at module top) to mirror monitoring.py's own lazy
    # import of this module — belt-and-suspenders against an import cycle.
    from bossman.services.monitoring import load_rule_ou_links, resolve_effective_rule

    rules = (await session.scalars(select(CheckRule).where(CheckRule.enabled == True))).all()  # noqa: E712
    rule_ou_links = await load_rule_ou_links(session)
    thresholds: dict[str, dict] = {}
    for metric in sorted({r.metric for r in rules}):
        rule = resolve_effective_rule(
            list(rules), agent.name, agent.groups, metric, None,
            host_ou_ancestry=host_ou_ancestry, rule_ou_links=rule_ou_links,
        )
        if rule is None or (rule.warn_threshold is None and rule.crit_threshold is None):
            continue
        # Source (Block G, the GPO settings editor): which level set this
        # threshold — host / ou:<path> / group:<name> / global.
        if rule.scope_type == "ou":
            ou_path = next((str(n.path) for n in host_ou_ancestry if n.id == rule.scope_ou_id), str(rule.scope_ou_id))
            source = "ou:" + ou_path
        elif rule.scope_type in ("group", "host"):
            source = f"{rule.scope_type}:{rule.scope_value}"
        else:
            # Fleet-wide rules are presented as the auto-created "Default Policy"
            # rather than a nameless "global" scope (the seed IS that policy).
            source = "Default Policy"
        thresholds[metric] = {
            "warn": rule.warn_threshold,
            "crit": rule.crit_threshold,
            "comparison": rule.comparison,
            "service_name": rule.service_name,
            "source": source,
        }
    return thresholds


def _canonical_hash(state: dict) -> str:
    """sha256 of the canonical JSON (sorted keys, no whitespace jitter) so
    an identical desired state always hashes identically across compiles."""
    canonical = json.dumps(state, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


async def _build_desired_state(
    session: AsyncSession, agent: Agent, extra_candidate_link: OrchestrationPlanLink | None = None
) -> tuple[dict, dict]:
    """The pure "assemble the document" half of compiling a host's desired
    state — shared by compile_host_desired_state (persists it) and
    preview_plan_link (never touches the DB). Takes no None-agent case;
    callers resolve the agent first."""
    ancestry = await resolve_ou_ancestry(session, agent.ou_id)
    assignments = await resolve_orchestration_assignments(session, agent, extra_candidate_link)
    monitoring = derive_generated_monitoring(assignments)

    # Block L4-behavioral: fold the GPO-resolved check_rule thresholds into
    # monitoring.thresholds so the OU/GPO console's human-set thresholds reach
    # the host, not just plan-authored defaults. check_rules WIN over a
    # plan-authored key of the same name — the console is the deliberate,
    # host-specific config; a plan's generated_monitoring is a role default.
    check_thresholds = await resolve_host_thresholds(session, agent, ancestry)
    monitoring["thresholds"] = {**monitoring.get("thresholds", {}), **check_thresholds}

    # A role-type plan contributes its own name as a role; additionally any
    # plan (a "Policy") may declare extra roles inline via
    # generated_monitoring.roles (Block L3f — the multi-entry policy editor),
    # so one Policy can carry several roles at once.
    roles: set[str] = {a.plan_name for a in assignments if a.plan_type == "role"}
    for a in assignments:
        for r in (a.generated_monitoring or {}).get("roles", []) or []:
            roles.add(r)

    state = {
        "host": {
            "name": agent.name,
            "ou": ancestry[-1].path if ancestry else None,
        },
        "monitoring": monitoring,
        "orchestration": {
            "roles": sorted(roles),
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
    return state, explain


async def compile_host_desired_state(session: AsyncSession, agent_id: UUID) -> CompiledState | None:
    """Build the host's desired-state document, hash it, and — only if the
    hash differs from the current is_current row — retire that row and write
    a new generation. Returns None if the agent doesn't exist. Does not
    commit; the caller owns the transaction boundary (matching
    services/templates.py)."""
    agent = await session.scalar(select(Agent).where(Agent.id == agent_id))
    if agent is None:
        return None

    state, explain = await _build_desired_state(session, agent)
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


async def preview_plan_link(
    session: AsyncSession,
    tenant_id: UUID,
    plan_id: UUID,
    target_type: str,
    *,
    plan_version: int | None = None,
    ou_id: UUID | None = None,
    agent_id: UUID | None = None,
    host_group_id: UUID | None = None,
    parameters: dict | None = None,
) -> dict | None:
    """Block L2's safe "propose" primitive: computes what a NOT-YET-CREATED
    link would do — blast radius (how many/which hosts) and a before/after
    monitoring diff for one representative affected host — without writing
    anything to the database. Returns None if the plan doesn't exist. This
    is what the MCP dry-run tool calls; nothing here ever touches
    compiled_host_state or orchestration_plan_links.

    v1 simplification: the diff is computed against a single sample host
    (the first affected one), not every affected host individually — good
    enough to judge a proposal's shape before approval; a documented future
    extension if per-host divergence within one scope turns out to matter."""
    plan = await session.scalar(select(OrchestrationPlan).where(OrchestrationPlan.id == plan_id))
    if plan is None:
        return None
    version = await _plan_version(session, plan, plan_version)
    if version is None:
        return None

    affected = await affected_agent_ids(
        session, target_type, ou_id=ou_id, agent_id=agent_id, host_group_id=host_group_id, tenant_id=tenant_id
    )

    # A synthetic, never-added-to-session candidate link — resolve_orchestration_assignments
    # only reads its plain attributes, so a bare unpersisted instance is enough.
    candidate = OrchestrationPlanLink(
        tenant_id=tenant_id, plan_id=plan_id, plan_version=plan_version, target_type=target_type,
        ou_id=ou_id, agent_id=agent_id, host_group_id=host_group_id, parameters=parameters or {},
        priority=100, link_order=100, status="active",
    )

    sample_diff = None
    if affected:
        sample = await session.scalar(select(Agent).where(Agent.id == affected[0]))
        if sample is not None:
            before, _ = await _build_desired_state(session, sample)
            after, _ = await _build_desired_state(session, sample, extra_candidate_link=candidate)
            sample_diff = {
                "host": sample.name,
                "checks_added": sorted(set(after["monitoring"]["checks"]) - set(before["monitoring"]["checks"])),
                "roles_added": sorted(set(after["orchestration"]["roles"]) - set(before["orchestration"]["roles"])),
            }

    return {
        "plan_name": plan.name,
        "plan_version": version.version,
        "affected_host_count": len(affected),
        "sample_diff": sample_diff,
    }
