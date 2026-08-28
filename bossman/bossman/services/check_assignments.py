"""Resolve a host's effective checks from CheckAssignments (Block G9-P2).

Same GPO model as the orchestration compiler: an assignment reaches a host
if it is host-direct, on a group the host is in, or on an OU on the host's
ancestry path. Per check_name the winner is the most specific scope
(host > group > OU-deep > OU-shallow); parameters are merged so a more
specific scope overrides an inherited one key-by-key. This is how "warn
levels configured per host / group / OU" (user decision) is realized —
e.g. an OU 'Databases' carries the MySQL check with default levels, a
single host overrides one threshold.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, CheckAssignment, HostGroup, HostLabel
from bossman.services import gpo, rule_conditions
from bossman.services.compiler import resolve_host_group_ids, resolve_ou_ancestry


async def build_match_context(
    session: AsyncSession, agent: Agent, ancestry=None, *,
    service_name: str | None = None, service_labels: dict[str, str] | None = None,
) -> rule_conditions.MatchContext:
    """Everything a rule condition is evaluated against, for one host.

    Shared by both rule engines (assignments here, thresholds in services/monitoring), so
    "what does host_tags mean" is answered in exactly one place. `ancestry` is accepted
    pre-computed because the caller usually already has it; the host-label lookup is a
    query, so this is built once per host and never per rule.

    `service_name`/`service_labels` are for the service-level engine. Left None, the
    service conditions are not judged at all — a rule scoped to "Disk /var" must not
    disappear from the host merely because no service is in hand yet.
    """
    if ancestry is None:
        ancestry = await resolve_ou_ancestry(session, agent.ou_id)
    labels = (
        await session.scalars(select(HostLabel).where(HostLabel.agent_id == agent.id))
    ).all()
    # Bossman condition dimensions: flattened Ansible facts + the host's resolved
    # desired-state variables (services/scope_vars). Imported lazily so the module
    # graph stays acyclic (scope_vars imports compiler resolvers, as we do).
    from bossman.services.scope_vars import resolve_scope_vars

    host_vars = await resolve_scope_vars(session, agent)
    # Group NAMES, so a condition can be written the way an operator says it ("webservers") rather
    # than as a uuid. resolve_host_group_ids already expands group PATHS, so a host in
    # "Europe/Latvia" also reports "Europe" — the same inheritance the group tree shows, and the
    # reason a condition on a parent group reaches its children without being restated.
    group_ids = await resolve_host_group_ids(session, agent.id)
    group_names: list[str] = []
    if group_ids:
        group_names = [
            n for n in (await session.scalars(
                select(HostGroup.name).where(HostGroup.id.in_(list(group_ids)))
            )).all() if n
        ]
    return rule_conditions.MatchContext(
        host_name=agent.name or "",
        ou_paths=[n.path for n in ancestry if getattr(n, "path", None)],
        host_tags={str(k): str(v) for k, v in (agent.tags or {}).items()},
        host_labels={r.key: r.value for r in labels},
        service_name=service_name,
        service_labels=dict(service_labels or {}),
        host_facts=rule_conditions.flatten_facts(agent.facts or {}),
        host_vars={str(k): str(v) for k, v in host_vars.items()},
        host_groups=group_names,
    )


async def filter_agent_ids(
    session: AsyncSession, agent_ids: list, conditions: dict | None,
) -> list:
    """Narrow a scope's host list by the shared rule-conditions object.

    The batch counterpart to build_match_context: ComplianceRule, ScheduledJob and BusinessService all
    resolve their hosts through affected_agent_ids and then iterate, so they need "and of those, the
    ones the condition matches" rather than a per-event predicate. One helper, because three copies of
    a matcher is how two of them end up disagreeing about what host_groups means.

    Returns the list UNCHANGED when there is no condition — and does so without touching the database.
    An empty condition matches everywhere (rule_conditions' contract), so a rule written before its
    kind had the column behaves exactly as it did, and the common case costs nothing.
    """
    if not conditions:
        return list(agent_ids)
    out = []
    for aid in agent_ids:
        agent = await session.get(Agent, aid)
        if agent is None:
            continue  # a scope that names a host which no longer exists contributes nothing
        ctx = await build_match_context(session, agent)
        if rule_conditions.matches(conditions, ctx):
            out.append(aid)
    return out


@dataclass
class EffectiveCheck:
    check_name: str
    parameters: dict[str, Any]
    source_scope: str          # 'host' | 'group' | 'ou'
    source_scope_id: str | None
    assignment_id: str         # the winning (most specific) assignment
    contributing: list[str] = field(default_factory=list)  # all assignment ids that merged in

    def to_dict(self) -> dict[str, Any]:
        return {
            "check_name": self.check_name,
            "parameters": self.parameters,
            "source_scope": self.source_scope,
            "source_scope_id": self.source_scope_id,
            "assignment_id": self.assignment_id,
            "contributing": self.contributing,
        }


async def resolve_host_checks(session: AsyncSession, agent: Agent) -> list[EffectiveCheck]:
    """Every check that applies to `agent`, deduped per check_name with
    host > group > OU precedence and inherited-then-specific param merge."""
    ancestry = await resolve_ou_ancestry(session, agent.ou_id)  # root … leaf
    ancestry_depth = {n.id: depth for depth, n in enumerate(ancestry)}
    group_ids = await resolve_host_group_ids(session, agent.id)

    clauses = [and_(CheckAssignment.scope_type == "host", CheckAssignment.agent_id == agent.id)]
    if group_ids:
        clauses.append(and_(CheckAssignment.scope_type == "group", CheckAssignment.host_group_id.in_(group_ids)))
    if ancestry_depth:
        clauses.append(and_(CheckAssignment.scope_type == "ou", CheckAssignment.ou_id.in_(list(ancestry_depth))))

    rows = (
        await session.scalars(
            select(CheckAssignment).where(
                CheckAssignment.tenant_id == agent.tenant_id,
                CheckAssignment.enabled.is_(True),
                or_(*clauses),
            )
        )
    ).all()

    # Checkmk's six condition fields, on top of the structural scope. The scope says WHERE
    # a rule can reach; the condition says whether it actually applies there. Built once
    # per host — the label lookup is a query, so it must not happen per rule. An assignment
    # with no condition passes unchanged, which is every rule written before this existed.
    if any(a.conditions for a in rows):
        ctx = await build_match_context(session, agent, ancestry)
        rows = [a for a in rows if rule_conditions.matches(a.conditions, ctx)]

    def level(a: CheckAssignment) -> int:
        if a.scope_type == "host":
            return gpo.LEVEL_HOST
        if a.scope_type == "group":
            return gpo.LEVEL_GROUP
        return gpo.LEVEL_OU_BASE + ancestry_depth.get(a.ou_id, 0)

    # group by (check_name, instance); sort each group least→most specific for
    # the merge. The instance is what makes two assignments of the SAME check
    # distinct services, and Checkmk's answer is the pair (plugin, ITEM) — one
    # service per filesystem, per interface, per sensor.
    #
    # It used to be `service_name` alone, which active service checks (http/tcp/
    # dns, Block S) set to name several instances on one host ("Health Qwen7b").
    # But a discovered multi-item check has no service_name: /discover/apply
    # writes one assignment per item with params.item, and all of them then
    # collapsed into ONE effective check. lnx_if, assigned for four interfaces,
    # produced a single service called "lnx_if" reporting "no item specified" —
    # the item dimension existed at both ends and was lost exactly here.
    per_check: dict[tuple[str, str, str], list[CheckAssignment]] = {}
    for a in rows:
        params = a.parameters or {}
        instance = str(params.get("service_name") or "")
        item = str(params.get("item") or "")
        per_check.setdefault((a.check_name, instance, item), []).append(a)

    out: list[EffectiveCheck] = []
    for (check_name, _instance, _item), assignments in sorted(per_check.items()):
        ordered = sorted(assignments, key=level)  # shallow OU → deep OU → group → host
        merged: dict[str, Any] = {}
        for a in ordered:
            merged.update(a.parameters or {})   # more specific overrides
        winner = ordered[-1]
        out.append(
            EffectiveCheck(
                check_name=check_name,
                parameters=merged,
                source_scope=winner.scope_type,
                source_scope_id=str(winner.ou_id or winner.host_group_id or winner.agent_id or "") or None,
                assignment_id=str(winner.id),
                contributing=[str(a.id) for a in ordered],
            )
        )
    return out
