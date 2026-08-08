"""OU tree CRUD (Block L1) — the AD-style organizational-unit hierarchy a
host lives at exactly one node of (Agent.ou_id). Every node's `path` is a
materialized slash-path recomputed from its ancestry on create/move, so
reads never need a recursive query.

Explicit select() queries throughout — no ORM relationship traversal
(matches services/templates.py's/compiler.py's MissingGreenlet-avoidance
convention from Block K11).
"""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import or_, select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

import re

from bossman.api.auth import get_current_identity
from bossman.api.management import _merge_values, remove_desired_key
from bossman.api.plans import get_client_factory
from bossman.config import get_settings
from bossman.db.models import (
    DEFAULT_TENANT_ID,
    Agent,
    CheckRule,
    CheckRuleOuLink,
    ConfigPolicy,
    ConfigPolicySet,
    HostGroup,
    Site,
    NotificationRule,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OUNode,
    ScopeVars,
)
from bossman.db.session import get_session
from bossman.services import gpo
from bossman.services.agent_client import AgentClientError
from bossman.services.compiler import affected_agent_ids, compile_host_desired_state, resolve_ou_ancestry
from bossman.services.config_desired import effective_resources

router = APIRouter()


def _ltree_segment(name: str) -> str:
    """Sanitize an OU display name into a single ltree label (PG16 allows
    [A-Za-z0-9_-]; everything else, including spaces, becomes '_'). A blank
    result falls back to '_' so the label is always valid."""
    seg = re.sub(r"[^A-Za-z0-9_-]", "_", name.strip())
    return seg or "_"

# L1 is single-tenant-aware but not multi-tenant-selectable yet — every
# request implicitly operates on the seeded default tenant, matching how
# the rest of Bossman's REST surface has no tenant selector either. A
# tenant-picking UI/API is out of scope until a real second tenant exists.
DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


class OUNodeIn(BaseModel):
    name: str
    parent_id: UUID | None = None


class OUNodeOut(BaseModel):
    id: UUID
    parent_id: UUID | None
    name: str
    path: str
    ltree_path: str
    block_inheritance: bool
    created_at: datetime

    @classmethod
    def from_model(cls, node: OUNode) -> "OUNodeOut":
        return cls(
            id=node.id, parent_id=node.parent_id, name=node.name, path=node.path,
            ltree_path=str(node.ltree_path), block_inheritance=node.block_inheritance, created_at=node.created_at,
        )


async def _get_ou_or_404(session: AsyncSession, ou_id: UUID) -> OUNode:
    node = await session.get(OUNode, ou_id)
    if node is None or node.tenant_id != DEFAULT_TENANT_ID:
        raise HTTPException(status_code=404, detail=f"no such OU node {ou_id}")
    return node


@router.get("/api/v1/ou", response_model=list[OUNodeOut])
async def list_ou_nodes(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[OUNodeOut]:
    rows = (
        await session.scalars(
            select(OUNode).where(OUNode.tenant_id == DEFAULT_TENANT_ID, OUNode.deleted_at.is_(None)).order_by(OUNode.path)
        )
    ).all()
    return [OUNodeOut.from_model(n) for n in rows]


@router.post("/api/v1/ou", response_model=OUNodeOut)
async def create_ou_node(
    body: OUNodeIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> OUNodeOut:
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    parent_path = ""
    parent_ltree = ""
    if body.parent_id is not None:
        parent = await _get_ou_or_404(session, body.parent_id)
        parent_path = parent.path
        parent_ltree = str(parent.ltree_path)
    segment = _ltree_segment(body.name)
    ltree_path = f"{parent_ltree}.{segment}" if parent_ltree else segment
    node = OUNode(
        id=uuid4(), tenant_id=DEFAULT_TENANT_ID, parent_id=body.parent_id, name=body.name,
        path=f"{parent_path}/{body.name}", ltree_path=ltree_path,
    )
    session.add(node)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"an OU named {body.name!r} already exists under this parent") from exc
    return OUNodeOut.from_model(node)


class OUMoveRequest(BaseModel):
    # The OU's new parent; null = move to the forest root.
    parent_id: UUID | None = None


@router.post("/api/v1/ou/{ou_id}/move", response_model=OUNodeOut)
async def move_ou_node(
    ou_id: UUID,
    body: OUMoveRequest,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> OUNodeOut:
    """Reparent an OU (the drag-and-drop move, Block L3e). Rewrites the
    materialized `path` + `ltree_path` of the node AND its whole subtree, then
    recompiles every host under it (OU-scoped rules + GPO precedence change
    with the new depth/ancestry). Rejects a move into the node's own subtree
    (a cycle) and a name collision under the new parent."""
    node = await _get_ou_or_404(session, ou_id)
    old_ltree = str(node.ltree_path)
    old_path = node.path

    parent_path, parent_ltree = "", ""
    if body.parent_id is not None:
        if body.parent_id == ou_id:
            raise HTTPException(status_code=422, detail="an OU cannot be its own parent")
        parent = await _get_ou_or_404(session, body.parent_id)
        # Cycle guard: the new parent must not be inside the moved subtree.
        if str(parent.ltree_path) == old_ltree or await session.scalar(
            select(OUNode.id).where(OUNode.id == body.parent_id).where(
                text("ou_nodes.ltree_path <@ :old ::ltree")
            ).params(old=old_ltree)
        ):
            raise HTTPException(status_code=422, detail="cannot move an OU into its own subtree")
        parent_path, parent_ltree = parent.path, str(parent.ltree_path)

    segment = _ltree_segment(node.name)
    new_ltree = f"{parent_ltree}.{segment}" if parent_ltree else segment
    new_path = f"{parent_path}/{node.name}"

    if new_ltree == old_ltree:
        return OUNodeOut.from_model(node)  # already there — no-op

    # Rewrite the subtree's materialized paths: keep each node's tail relative
    # to the moved node's PARENT (subpath from nlevel(old)-1 retains the moved
    # node's own label and everything below it), and prepend the new parent's
    # ltree ('' for a move to the forest root). Using nlevel(old)-1 (not
    # nlevel(old)) avoids subpath's out-of-range error on the moved node
    # itself, whose level equals nlevel(old).
    try:
        await session.execute(
            text(
                "UPDATE ou_nodes SET ltree_path = (:pl ::ltree || subpath(ltree_path, nlevel(:old ::ltree) - 1)) "
                "WHERE ltree_path <@ :old ::ltree"
            ).params(pl=parent_ltree, old=old_ltree)
        )
        await session.execute(
            text(
                "UPDATE ou_nodes SET path = (:newp || substring(path FROM char_length(:oldp) + 1)) "
                "WHERE path = :oldp OR path LIKE :oldp || '/%'"
            ).params(newp=new_path, oldp=old_path)
        )
        await session.execute(
            text("UPDATE ou_nodes SET parent_id = :pid WHERE id = :id").params(
                pid=str(body.parent_id) if body.parent_id else None, id=str(ou_id)
            )
        )
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(
            status_code=409, detail=f"an OU named {node.name!r} already exists under the target parent"
        ) from exc

    # Recompile every host now under the moved subtree (their ancestry changed).
    for agent_id in await affected_agent_ids(session, "ou", ou_id=ou_id, tenant_id=DEFAULT_TENANT_ID):
        await compile_host_desired_state(session, agent_id)
    await session.commit()

    refreshed = await _get_ou_or_404(session, ou_id)
    return OUNodeOut.from_model(refreshed)


class OUNodePatch(BaseModel):
    block_inheritance: bool


@router.patch("/api/v1/ou/{ou_id}", response_model=OUNodeOut)
async def patch_ou_node(
    ou_id: UUID,
    body: OUNodePatch,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> OUNodeOut:
    """Toggle GPO "Block Inheritance" on an OU. Since this changes which
    inherited rules apply to every host in this OU's subtree, it recompiles
    them all (analogous to a plan-link change)."""
    node = await _get_ou_or_404(session, ou_id)
    node.block_inheritance = body.block_inheritance
    await session.commit()
    for agent_id in await affected_agent_ids(session, "ou", ou_id=ou_id, tenant_id=DEFAULT_TENANT_ID):
        await compile_host_desired_state(session, agent_id)
    await session.commit()
    return OUNodeOut.from_model(node)


@router.delete("/api/v1/ou/{ou_id}", status_code=204)
async def delete_ou_node(
    ou_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    node = await _get_ou_or_404(session, ou_id)
    child = await session.scalar(select(OUNode.id).where(OUNode.parent_id == ou_id))
    if child is not None:
        raise HTTPException(status_code=409, detail="cannot delete an OU that still has child OUs")
    hosted = await session.scalar(select(Agent.id).where(Agent.ou_id == ou_id))
    if hosted is not None:
        raise HTTPException(status_code=409, detail="cannot delete an OU that still has hosts placed in it")
    await session.delete(node)
    await session.commit()


@router.get("/api/v1/ou/{ou_id}/ancestry", response_model=list[OUNodeOut])
async def get_ou_ancestry(
    ou_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[OUNodeOut]:
    await _get_ou_or_404(session, ou_id)
    chain = await resolve_ou_ancestry(session, ou_id)
    return [OUNodeOut.from_model(n) for n in chain]


class OUObject(BaseModel):
    """One policy object directly attached to an OU (Block L3a) — the tree
    UI's per-node child list. `kind` discriminates the object type; the
    common GPO fields (enforced/enabled) drive the tree's status markers."""

    kind: str  # check_rule | notification | host_group | orchestration_link | config_policy
    id: UUID
    label: str
    enforced: bool = False
    enabled: bool = True
    # For orchestration_link only: the underlying plan, so the palette can
    # re-scope a link to another OU by relinking that plan (Block L3e).
    plan_id: UUID | None = None


@router.get("/api/v1/ou/{ou_id}/objects", response_model=list[OUObject])
async def list_ou_objects(
    ou_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> list[OUObject]:
    """Every policy object attached DIRECTLY to this OU (not inherited) —
    check-rules/thresholds, notification rules, host groups, and
    orchestration plan links — the child nodes the GPO tree shows under an
    OU. Inheritance/effective resolution is a separate concern (the
    compiler / desired-state view)."""
    await _get_ou_or_404(session, ou_id)
    out: list[OUObject] = []

    # Threshold policies attached to this OU — both those whose primary scope
    # is this OU and those linked to it via check_rule_ou_links (one policy →
    # many OUs). Union + dedup so a multi-linked policy shows once per OU.
    linked_rule_ids = set(
        (await session.scalars(select(CheckRuleOuLink.rule_id).where(CheckRuleOuLink.ou_id == ou_id))).all()
    )
    conds = [CheckRule.scope_ou_id == ou_id]
    if linked_rule_ids:
        conds.append(CheckRule.id.in_(linked_rule_ids))
    for r in (await session.scalars(select(CheckRule).where(or_(*conds)))).all():
        label = f"{r.service_name} ({r.metric} {r.comparison} {r.warn_threshold}/{r.crit_threshold})"
        out.append(OUObject(kind="check_rule", id=r.id, label=label, enforced=r.enforced, enabled=r.enabled))

    for n in (await session.scalars(select(NotificationRule).where(NotificationRule.ou_id == ou_id))).all():
        out.append(
            OUObject(kind="notification", id=n.id, label=f"{n.name} → {n.channel}", enforced=n.enforced, enabled=n.enabled)
        )

    for g in (await session.scalars(select(HostGroup).where(HostGroup.ou_id == ou_id, HostGroup.deleted_at.is_(None)))).all():
        out.append(OUObject(kind="host_group", id=g.id, label=g.name))

    # Variables set on this OU appear as their own tree object (like a GPO's
    # "Preferences" node) so they're visible/editable in the tree, not only in
    # the report. id = the ScopeVars row; label shows how many keys.
    sv = await session.scalar(
        select(ScopeVars).where(ScopeVars.ou_id == ou_id, ScopeVars.scope_type == "ou")
    )
    if sv and sv.vars:
        out.append(OUObject(kind="variables", id=sv.id, label=f"Variables ({len(sv.vars)})"))

    # NOTE: Sites are NOT listed here. Like AD Sites-and-Services, a Site is a
    # TOP-LEVEL container directly under Root (subnet-scoped), not nested under an
    # OU — the UI renders them as their own node, served by /api/v1/policy-sites.

    # Block K4: OU-scoped config policies (one desired config file → every host
    # under the OU). Label: the path + how many keys (or "template").
    for cp in (await session.scalars(select(ConfigPolicy).where(ConfigPolicy.scope_ou_id == ou_id))).all():
        detail = "template" if cp.type == "template_render" else f"{len(cp.values or {})} keys"
        out.append(OUObject(kind="config_policy", id=cp.id, label=f"{cp.path} ({detail})"))

    links = (await session.scalars(select(OrchestrationPlanLink).where(OrchestrationPlanLink.ou_id == ou_id))).all()
    for link in links:
        plan = await session.get(OrchestrationPlan, link.plan_id)
        label = f"{plan.display_name if plan else link.plan_id} [{link.status}]"
        out.append(
            OUObject(
                kind="orchestration_link", id=link.id, label=label,
                enforced=link.enforced, enabled=link.enabled, plan_id=link.plan_id,
            )
        )
    return out


# ---------------------------------------------------------------------------
# Policy report (RSoP): what actually applies at an OU / Site / group


class PolicyReportRow(BaseModel):
    kind: str          # 'config' | 'threshold' | 'plan' | 'notification'
    label: str
    detail: str        # human summary (path+keys / metric comparison / plan type)
    origin: str        # 'here' | 'OU /Foo' | 'Global (whole fleet)'
    enforced: bool = False


class PolicyVarRow(BaseModel):
    key: str
    value: str
    origin: str


class PolicyReportOut(BaseModel):
    scope_type: str
    scope_label: str
    variables: list[PolicyVarRow]
    rows: list[PolicyReportRow]


def _effective_threshold_rows(candidates: list[tuple[CheckRule, int, str]]) -> list[PolicyReportRow]:
    """Resolve a scope's applicable threshold rules to the RESULTANT set: exactly
    one row per (metric, label_value), the GPO winner — so the report shows only
    what actually applies, not every candidate. Two rules on the same metric (an
    inherited default vs one set here) collapse to the one that wins, matching
    services/monitoring.resolve_effective_rule / services/gpo.resolve_winner.

    `candidates` is (rule, gpo_level, origin_label) for every rule that could
    apply at this scope."""
    from collections import defaultdict

    groups: dict[tuple, list[tuple[CheckRule, int, str]]] = defaultdict(list)
    for rule, level, origin in candidates:
        groups[(rule.metric, rule.label_value)].append((rule, level, origin))

    rows: list[PolicyReportRow] = []
    for members in groups.values():
        gcands = [
            gpo.GpoCandidate(
                obj=(rule, origin),
                enforced=bool(rule.enforced),
                level=level,
                link_order=rule.link_order if rule.link_order is not None else 100,
                created_ts=rule.created_at.timestamp() if rule.created_at else 0.0,
            )
            for rule, level, origin in members
        ]
        won = gpo.resolve_winner(gcands)
        if won is None:
            continue
        rule, origin = won
        rows.append(PolicyReportRow(
            kind="threshold", label=rule.service_name,
            detail=f"{rule.metric} {rule.comparison} {rule.warn_threshold}/{rule.crit_threshold}",
            origin=origin, enforced=rule.enforced))
    return rows


@router.get("/api/v1/policy-report", response_model=PolicyReportOut)
async def policy_report(
    scope_type: str,
    scope_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> PolicyReportOut:
    """Resultant Set of Policy for one scope — what actually applies to hosts here
    and WHERE each rule comes from. Unlike the objects endpoint (own-scope only),
    this INHERITS: an OU shows its own policies plus everything from its ancestor
    OUs and the global tier; a Site shows its own plus global; a group its own plus
    global. Origin is labelled so you can see 'here' vs inherited. Ordering follows
    OUR precedence (weakest first, closest-to-host last) so the bottom rows win.

    This backs the right-hand 'policy report' on the OU/Policy page (replacing the
    inline editor there) and finally surfaces OU/group Variables, which were set
    but never shown."""
    rows: list[PolicyReportRow] = []
    variables: list[PolicyVarRow] = []

    if scope_type == "ou":
        ou = await session.get(OUNode, scope_id)
        if ou is None:
            raise HTTPException(status_code=404, detail=f"no such OU {scope_id}")
        scope_label = f"OU {ou.path}"
        ancestry = await resolve_ou_ancestry(session, scope_id)  # root→this
        ancestry_ids = [o.id for o in ancestry]
        origin_of = {o.id: ("here" if o.id == scope_id else f"OU {o.path}") for o in ancestry}

        # Config policies: own + every ancestor OU (closest-to-host wins at compile).
        for cp in (await session.scalars(
            select(ConfigPolicy).where(ConfigPolicy.scope_ou_id.in_(ancestry_ids))
        )).all():
            detail = "template" if cp.type == "template_render" else f"{len(cp.values or {})} keys"
            rows.append(PolicyReportRow(kind="config", label=cp.path, detail=detail,
                                        origin=origin_of.get(cp.scope_ou_id, "OU")))
        # Threshold rules: global tier + own/ancestor OUs (direct scope or via
        # links). Collect every candidate with its GPO level, then reduce to the
        # RESULTANT set (one winner per metric) so two rules on the same metric
        # don't both show — only the one that actually applies.
        depth_of = {o.id: i for i, o in enumerate(ancestry)}  # root=0 … this OU deepest
        link_ou = {rid: oid for oid, rid in (
            await session.execute(
                select(CheckRuleOuLink.ou_id, CheckRuleOuLink.rule_id)
                .where(CheckRuleOuLink.ou_id.in_(ancestry_ids))
            )).all()}
        th_cands: list[tuple[CheckRule, int, str]] = []
        for r in (await session.scalars(select(CheckRule).where(CheckRule.enabled == True))).all():  # noqa: E712
            if r.scope_type == "global":
                th_cands.append((r, gpo.LEVEL_GLOBAL, "Global (whole fleet)"))
                continue
            if r.scope_type != "ou":
                continue
            # Deepest OU on this scope's ancestry the rule targets wins (direct
            # scope_ou_id or any linked OU) — closest-to-host under GPO.
            ous = {r.scope_ou_id} if r.scope_ou_id in depth_of else set()
            if r.id in link_ou and link_ou[r.id] in depth_of:
                ous.add(link_ou[r.id])
            if not ous:
                continue
            best = max(ous, key=lambda o: depth_of[o])
            th_cands.append((r, gpo.LEVEL_OU_BASE + depth_of[best], origin_of.get(best, "OU")))
        rows.extend(_effective_threshold_rows(th_cands))
        # Orchestration plans linked to own/ancestor OUs.
        for link in (await session.scalars(
            select(OrchestrationPlanLink).where(OrchestrationPlanLink.ou_id.in_(ancestry_ids))
        )).all():
            plan = await session.get(OrchestrationPlan, link.plan_id)
            rows.append(PolicyReportRow(
                kind="plan", label=plan.display_name if plan else str(link.plan_id),
                detail=(plan.plan_type if plan else "plan") + f" [{link.status}]",
                origin=origin_of.get(link.ou_id, "OU"), enforced=link.enforced))
        # Notifications on own/ancestor OUs.
        for n in (await session.scalars(
            select(NotificationRule).where(NotificationRule.ou_id.in_(ancestry_ids))
        )).all():
            rows.append(PolicyReportRow(kind="notification", label=n.name, detail=n.channel,
                                        origin=origin_of.get(n.ou_id, "OU"), enforced=n.enforced))
        # Variables: own + inherited (own wins at runtime; show all with origin).
        for sv in (await session.scalars(
            select(ScopeVars).where(ScopeVars.ou_id.in_(ancestry_ids))
        )).all():
            for k, v in (sv.vars or {}).items():
                variables.append(PolicyVarRow(key=k, value=str(v), origin=origin_of.get(sv.ou_id, "OU")))

    elif scope_type == "site":
        site = await session.get(Site, scope_id)
        if site is None:
            raise HTTPException(status_code=404, detail=f"no such site {scope_id}")
        scope_label = f"Site {site.name}"
        for cp in (await session.scalars(select(ConfigPolicy).where(ConfigPolicy.site_id == scope_id))).all():
            detail = "template" if cp.type == "template_render" else f"{len(cp.values or {})} keys"
            rows.append(PolicyReportRow(kind="config", label=cp.path, detail=detail, origin="here"))
        th_cands = []
        for r in (await session.scalars(
            select(CheckRule).where(CheckRule.enabled == True)  # noqa: E712
        )).all():
            if r.scope_type == "global":
                th_cands.append((r, gpo.LEVEL_GLOBAL, "Global (whole fleet)"))
            elif r.scope_type == "site" and r.scope_site_id == scope_id:
                th_cands.append((r, gpo.LEVEL_SITE, "here"))
        rows.extend(_effective_threshold_rows(th_cands))
        for link in (await session.scalars(
            select(OrchestrationPlanLink).where(OrchestrationPlanLink.site_id == scope_id)
        )).all():
            plan = await session.get(OrchestrationPlan, link.plan_id)
            rows.append(PolicyReportRow(
                kind="plan", label=plan.display_name if plan else str(link.plan_id),
                detail=(plan.plan_type if plan else "plan") + f" [{link.status}]",
                origin="here", enforced=link.enforced))
        # Sites carry no variables (scope_vars is ou/group/host only).

    elif scope_type == "group":
        grp = await session.get(HostGroup, scope_id)
        if grp is None:
            raise HTTPException(status_code=404, detail=f"no such host group {scope_id}")
        scope_label = f"Group {grp.name}"
        for cp in (await session.scalars(select(ConfigPolicy).where(ConfigPolicy.host_group_id == scope_id))).all():
            detail = "template" if cp.type == "template_render" else f"{len(cp.values or {})} keys"
            rows.append(PolicyReportRow(kind="config", label=cp.path, detail=detail, origin="here"))
        th_cands = []
        for r in (await session.scalars(
            select(CheckRule).where(CheckRule.enabled == True)  # noqa: E712
        )).all():
            if r.scope_type == "global":
                th_cands.append((r, gpo.LEVEL_GLOBAL, "Global (whole fleet)"))
            elif r.scope_type == "group" and r.scope_value == grp.name:
                th_cands.append((r, gpo.LEVEL_GROUP, "here"))
        rows.extend(_effective_threshold_rows(th_cands))
        for sv in (await session.scalars(select(ScopeVars).where(ScopeVars.host_group_id == scope_id))).all():
            for k, v in (sv.vars or {}).items():
                variables.append(PolicyVarRow(key=k, value=str(v), origin="here"))
    else:
        raise HTTPException(status_code=422, detail="scope_type must be ou, site or group")

    return PolicyReportOut(scope_type=scope_type, scope_label=scope_label, variables=variables, rows=rows)


def _resolve_policy_scope(ou_id: UUID | None, group_id: UUID | None, site_id: UUID | None) -> tuple[str, UUID]:
    """Config policies are scoped to exactly one of OU / host-group / Site.
    Returns (kind, id) or raises 422 when zero or more than one is set."""
    chosen = [(k, v) for k, v in (("ou", ou_id), ("group", group_id), ("site", site_id)) if v is not None]
    if len(chosen) != 1:
        raise HTTPException(status_code=422, detail="set exactly one of scope_ou_id / host_group_id / site_id")
    return chosen[0]


class ConfigPolicyIn(BaseModel):
    """Author a config-value policy at OU, group or Site scope (gpedit's 'add a
    setting to a policy'). Exactly one of scope_ou_id / host_group_id / site_id.
    `values` is the desired key→value document for the file; a null value on a
    key enforces its absence. Persisting the policy is the authoring act; on a
    real (non-dry_run) save we also converge every reachable member host so it
    takes effect immediately, like linking a GPO."""

    scope_ou_id: UUID | None = None
    host_group_id: UUID | None = None
    site_id: UUID | None = None
    # Add this entry to a named Policy (ConfigPolicySet). The entry then inherits
    # the set's scope (so linking the set links every entry at once).
    set_id: UUID | None = None
    path: str
    type: str = "config"
    format: str | None = "keyvalue"
    separator: str | None = None
    values: dict = {}
    template: str | None = None
    dry_run: bool = False


@router.post("/api/v1/config-policies")
async def create_config_policy(
    body: ConfigPolicyIn,
    session: AsyncSession = Depends(get_session),
    settings=Depends(get_settings),
    _identity=Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict:
    """Create/update a config policy at OU/group scope and converge members
    (Block K4, authored from the Policy console). No agent context needed — you
    can define a policy for an OU that has no reachable host yet; it applies
    when hosts appear/re-sync."""
    # An entry added to a named Policy (set) inherits the SET's scope, so linking
    # the set links every entry at once. Resolve the set first and override scope.
    policy_set = None
    if body.set_id is not None:
        policy_set = await session.get(ConfigPolicySet, body.set_id)
        if policy_set is None:
            raise HTTPException(status_code=422, detail=f"no such policy set {body.set_id}")
        body.scope_ou_id, body.host_group_id, body.site_id = (
            policy_set.scope_ou_id, policy_set.host_group_id, policy_set.site_id)
    # Unlinked authoring (GPMC "create a GPO, link it later"): with NO scope the
    # policy is created inert — it applies to nothing until it is linked (dragged
    # onto an OU/Site, which rescopes it). This is what "New config policy" does
    # when no scope is selected, so authoring never demands a target up front.
    have_scope = any(v is not None for v in (body.scope_ou_id, body.host_group_id, body.site_id))
    if have_scope:
        scope_kind, scope_id = _resolve_policy_scope(body.scope_ou_id, body.host_group_id, body.site_id)
        if scope_kind == "ou" and await session.get(OUNode, scope_id) is None:
            raise HTTPException(status_code=422, detail=f"no such OU {scope_id}")
        if scope_kind == "group" and await session.get(HostGroup, scope_id) is None:
            raise HTTPException(status_code=422, detail=f"no such host group {scope_id}")
        if scope_kind == "site" and await session.get(Site, scope_id) is None:
            raise HTTPException(status_code=422, detail=f"no such site {scope_id}")
    else:
        scope_kind, scope_id = None, None

    if not body.dry_run:
        if body.set_id is not None:
            # An entry is unique by (set, path) — an unlinked set has null scope,
            # so scope+path wouldn't disambiguate two sets' /etc/motd entries.
            q = select(ConfigPolicy).where(ConfigPolicy.set_id == body.set_id, ConfigPolicy.path == body.path)
        elif scope_kind is None:
            # Match an existing unlinked policy for this path (all scope cols null).
            q = select(ConfigPolicy).where(
                ConfigPolicy.scope_ou_id.is_(None), ConfigPolicy.host_group_id.is_(None),
                ConfigPolicy.site_id.is_(None), ConfigPolicy.set_id.is_(None), ConfigPolicy.path == body.path)
        else:
            scope_col = {"ou": ConfigPolicy.scope_ou_id, "group": ConfigPolicy.host_group_id, "site": ConfigPolicy.site_id}[scope_kind]
            q = select(ConfigPolicy).where(scope_col == scope_id, ConfigPolicy.path == body.path)
        pol = await session.scalar(q)
        if pol is None:
            # DEFAULT_TENANT_ID may be a str or already a UUID depending on
            # import order (some modules coerce the module attribute) — str()
            # first so UUID() accepts it either way.
            pol = ConfigPolicy(
                tenant_id=UUID(str(DEFAULT_TENANT_ID)), path=body.path, set_id=body.set_id,
                scope_ou_id=scope_id if scope_kind == "ou" else None,
                host_group_id=scope_id if scope_kind == "group" else None,
                site_id=scope_id if scope_kind == "site" else None,
            )
            session.add(pol)
        pol.type = body.type
        pol.config_format = body.format
        pol.separator = body.separator
        if body.type == "template_render":
            pol.values = body.values  # template = whole-file, replace
        else:
            pol.values = _merge_values(pol.values, body.values, body.format)
        pol.template = body.template
        pol.updated_at = datetime.now(timezone.utc)
        await session.commit()

    resource = {
        "type": body.type, "path": body.path, "format": body.format,
        "separator": body.separator, "values": body.values, "template": body.template,
    }
    # An unlinked policy has no members to converge — it is inert until linked.
    member_ids = [] if scope_kind is None else await affected_agent_ids(
        session, scope_kind,
        ou_id=scope_id if scope_kind == "ou" else None,
        host_group_id=scope_id if scope_kind == "group" else None,
        site_id=scope_id if scope_kind == "site" else None,
        tenant_id=UUID(str(DEFAULT_TENANT_ID)),
    )
    applied, skipped = [], []
    for mid in member_ids:
        m = await session.get(Agent, mid)
        if m is None or not m.address:
            skipped.append(str(mid))
            continue
        # Apply the GPO-RESOLVED resource for this path (host > OU > group,
        # per key), NOT the raw OU policy — so a host's own setting keeps
        # overriding the OU policy. On dry_run the policy isn't persisted yet,
        # so effective_resources can't see it; fall back to the raw preview.
        push = resource
        if not body.dry_run:
            eff = await effective_resources(session, m)
            push = next((e["resource"] for e in eff if e["path"] == body.path), resource)
        try:
            await client_factory(m, settings).state_apply({"resources": [push]}, body.dry_run)
            applied.append(m.name)
        except AgentClientError:
            skipped.append(m.name)
    return {
        "scope": scope_kind,
        "scope_ou_id": str(scope_id) if scope_kind == "ou" else None,
        "host_group_id": str(scope_id) if scope_kind == "group" else None,
        "site_id": str(scope_id) if scope_kind == "site" else None,
        "applied_hosts": applied, "skipped_hosts": skipped, "dry_run": body.dry_run,
    }


@router.get("/api/v1/ou/{ou_id}/members")
async def list_ou_members(
    ou_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[dict]:
    """Agents in this OU's SUBTREE (policy semantics — a policy on /Munich
    reaches hosts in /Munich/mue-0 too). The Policy-console gpedit editor uses
    the first reachable member as its settings catalog ("Host A = Host B")."""
    await _get_ou_or_404(session, ou_id)
    out = []
    for agent_id in await affected_agent_ids(session, "ou", ou_id=ou_id):
        a = await session.get(Agent, agent_id)
        if a is not None:
            out.append({"id": str(a.id), "name": a.name, "address": a.address, "ou_id": str(a.ou_id) if a.ou_id else None})
    return out


@router.get("/api/v1/config-policies")
async def list_config_policies(
    scope_ou_id: UUID | None = None,
    host_group_id: UUID | None = None,
    site_id: UUID | None = None,
    set_id: UUID | None = None,
    unlinked: bool = False,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[dict]:
    """Config policies WITH their values documents, for the Policy-console
    gpedit editor (the OU objects list only carries a label). Filter by OU,
    group or Site scope, or by `set_id` (a named policy's entries); `unlinked=true`
    returns the scope-less policies not yet linked; no filter returns all."""
    stmt = select(ConfigPolicy)
    if set_id is not None:
        stmt = stmt.where(ConfigPolicy.set_id == set_id)
    if unlinked:
        # Bare unlinked entries only — those belonging to a named Policy (set_id)
        # are shown under their policy in the library, not as loose palette items.
        stmt = stmt.where(
            ConfigPolicy.scope_ou_id.is_(None), ConfigPolicy.host_group_id.is_(None),
            ConfigPolicy.site_id.is_(None), ConfigPolicy.set_id.is_(None))
    if scope_ou_id is not None:
        stmt = stmt.where(ConfigPolicy.scope_ou_id == scope_ou_id)
    if host_group_id is not None:
        stmt = stmt.where(ConfigPolicy.host_group_id == host_group_id)
    if site_id is not None:
        stmt = stmt.where(ConfigPolicy.site_id == site_id)
    return [
        {
            "id": str(cp.id),
            "scope_ou_id": str(cp.scope_ou_id) if cp.scope_ou_id else None,
            "host_group_id": str(cp.host_group_id) if cp.host_group_id else None,
            "site_id": str(cp.site_id) if cp.site_id else None,
            "path": cp.path, "type": cp.type, "format": cp.config_format,
            "separator": cp.separator, "values": cp.values or {}, "template": cp.template,
        }
        for cp in (await session.scalars(stmt)).all()
    ]


@router.get("/api/v1/config-policies/{policy_id}")
async def get_config_policy(
    policy_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """One config policy by id WITH its values — so a selected policy (in the tree
    or palette) can show exactly what it sets, without knowing its scope up front."""
    cp = await session.get(ConfigPolicy, policy_id)
    if cp is None:
        raise HTTPException(status_code=404, detail="no such config policy")
    return {
        "id": str(cp.id),
        "scope_ou_id": str(cp.scope_ou_id) if cp.scope_ou_id else None,
        "host_group_id": str(cp.host_group_id) if cp.host_group_id else None,
        "site_id": str(cp.site_id) if cp.site_id else None,
        "set_id": str(cp.set_id) if cp.set_id else None,
        "path": cp.path, "type": cp.type, "format": cp.config_format,
        "separator": cp.separator, "values": cp.values or {}, "template": cp.template,
    }


# ---------------------------------------------------------------------------
# Named policies (ConfigPolicySet): a container with a name + multiple entries


class PolicySetIn(BaseModel):
    name: str
    description: str | None = None


class PolicySetPatchIn(BaseModel):
    """Rename and/or (un)link the whole set. Setting a scope links it there and
    propagates to every entry; `unlink=true` detaches it (entries go inert)."""

    name: str | None = None
    description: str | None = None
    scope_ou_id: UUID | None = None
    host_group_id: UUID | None = None
    site_id: UUID | None = None
    unlink: bool = False


async def _policy_set_scope_label(session: AsyncSession, s: ConfigPolicySet) -> str:
    if s.scope_ou_id:
        ou = await session.get(OUNode, s.scope_ou_id)
        return f"OU {ou.path}" if ou else "OU"
    if s.site_id:
        site = await session.get(Site, s.site_id)
        return f"Site {site.name}" if site else "Site"
    if s.host_group_id:
        g = await session.get(HostGroup, s.host_group_id)
        return f"Group {g.name}" if g else "Group"
    return "(unlinked)"


async def _policy_set_out(session: AsyncSession, s: ConfigPolicySet, *, with_entries: bool) -> dict:
    entries = (await session.scalars(select(ConfigPolicy).where(ConfigPolicy.set_id == s.id).order_by(ConfigPolicy.path))).all()
    out = {
        "id": str(s.id), "name": s.name, "description": s.description,
        "scope_ou_id": str(s.scope_ou_id) if s.scope_ou_id else None,
        "host_group_id": str(s.host_group_id) if s.host_group_id else None,
        "site_id": str(s.site_id) if s.site_id else None,
        "scope_label": await _policy_set_scope_label(session, s),
        "entry_count": len(entries),
    }
    if with_entries:
        out["entries"] = [
            {"id": str(e.id), "path": e.path, "type": e.type, "format": e.config_format,
             "separator": e.separator, "values": e.values or {}, "template": e.template}
            for e in entries
        ]
        # Flat "all values at a glance" list for the far-right column of the Miller
        # browser: every key=value across every entry, tagged with its file.
        out["values_flat"] = [
            {"path": e.path, "key": k, "value": v}
            for e in entries if e.type != "template_render"
            for k, v in (e.values or {}).items()
        ]
    return out


@router.get("/api/v1/policy-sets")
async def list_policy_sets(
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> list[dict]:
    """The named-policy library (Miller column 1): every policy with its entry
    count + where (if anywhere) it is linked."""
    rows = (await session.scalars(select(ConfigPolicySet).order_by(ConfigPolicySet.name))).all()
    return [await _policy_set_out(session, s, with_entries=False) for s in rows]


@router.get("/api/v1/policy-sets/{set_id}")
async def get_policy_set(
    set_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> dict:
    """One policy with its entries + the flat 'all values' list (Miller columns
    2 and 3)."""
    s = await session.get(ConfigPolicySet, set_id)
    if s is None:
        raise HTTPException(status_code=404, detail="no such policy")
    return await _policy_set_out(session, s, with_entries=True)


@router.post("/api/v1/policy-sets", status_code=201)
async def create_policy_set(
    body: PolicySetIn, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> dict:
    """Create an empty named policy (unlinked). Entries are added via
    POST /config-policies with this set's id."""
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="name is required")
    s = ConfigPolicySet(tenant_id=UUID(str(DEFAULT_TENANT_ID)), name=name, description=body.description)
    session.add(s)
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a policy named {name!r} already exists")
    return await _policy_set_out(session, s, with_entries=True)


@router.patch("/api/v1/policy-sets/{set_id}")
async def patch_policy_set(
    set_id: UUID, body: PolicySetPatchIn,
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> dict:
    """Rename / describe / (un)link a policy. Linking sets the scope on the set
    AND propagates it to every entry, so the per-(scope,path) compiler applies the
    whole policy at that scope; unlink detaches all entries (they go inert)."""
    s = await session.get(ConfigPolicySet, set_id)
    if s is None:
        raise HTTPException(status_code=404, detail="no such policy")
    if body.name is not None:
        s.name = body.name.strip()
    if body.description is not None:
        s.description = body.description
    scope_touched = body.unlink or any(v is not None for v in (body.scope_ou_id, body.host_group_id, body.site_id))
    if scope_touched:
        chosen = [(k, v) for k, v in (("ou", body.scope_ou_id), ("group", body.host_group_id), ("site", body.site_id)) if v is not None]
        if not body.unlink and len(chosen) != 1:
            raise HTTPException(status_code=422, detail="link exactly one of scope_ou_id / host_group_id / site_id (or unlink)")
        s.scope_ou_id = body.scope_ou_id if not body.unlink else None
        s.host_group_id = body.host_group_id if not body.unlink else None
        s.site_id = body.site_id if not body.unlink else None
        # Propagate to entries so the compiler applies them at the new scope.
        for e in (await session.scalars(select(ConfigPolicy).where(ConfigPolicy.set_id == s.id))).all():
            e.scope_ou_id, e.host_group_id, e.site_id = s.scope_ou_id, s.host_group_id, s.site_id
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise HTTPException(status_code=409, detail="rename/link conflicts with an existing policy or entry at that scope")
    return await _policy_set_out(session, s, with_entries=True)


@router.delete("/api/v1/policy-sets/{set_id}", status_code=204)
async def delete_policy_set(
    set_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> None:
    """Delete a policy and all its entries (cascade)."""
    s = await session.get(ConfigPolicySet, set_id)
    if s is None:
        raise HTTPException(status_code=404, detail="no such policy")
    await session.delete(s)
    await session.commit()


class ConfigPolicyUnsetIn(BaseModel):
    scope_ou_id: UUID | None = None
    host_group_id: UUID | None = None
    site_id: UUID | None = None
    path: str
    key: str


@router.post("/api/v1/config-policies/unset")
async def unset_config_policy_key(
    body: ConfigPolicyUnsetIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """GPO "Not configured" at OU/group scope, agent-free (the Policy-console
    editor's counterpart of /agents/{id}/config-desired/unset): stop managing
    ONE key in a scope policy. Member hosts keep their live value; removing
    the last key deletes the policy row."""
    scope_kind, scope_id = _resolve_policy_scope(body.scope_ou_id, body.host_group_id, body.site_id)
    scope_col = {"ou": ConfigPolicy.scope_ou_id, "group": ConfigPolicy.host_group_id, "site": ConfigPolicy.site_id}[scope_kind]
    q = select(ConfigPolicy).where(scope_col == scope_id, ConfigPolicy.path == body.path)
    row = await session.scalar(q)
    if row is None:
        raise HTTPException(status_code=404, detail=f"no config policy for {body.path} at that scope")
    values = remove_desired_key(row, body.key)
    if values is None:
        raise HTTPException(status_code=404, detail=f"key {body.key} not managed")
    if not values and not row.template:
        await session.delete(row)
    else:
        row.values = values
        row.updated_at = datetime.now(timezone.utc)
    await session.commit()
    return {"path": body.path, "key": body.key, "unset": True}


class ConfigPolicyScopeIn(BaseModel):
    scope_ou_id: UUID | None = None
    host_group_id: UUID | None = None
    site_id: UUID | None = None


@router.patch("/api/v1/config-policies/{policy_id}")
async def rescope_config_policy(
    policy_id: UUID,
    body: ConfigPolicyScopeIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict:
    """Move a config policy to another OU/group scope (the OU-console 'drag a
    placed policy onto another OU' gesture). Exactly one of scope_ou_id /
    host_group_id. Doesn't re-converge here — member hosts pick it up on their
    next sync (deleting/adding a scope link mirrors unlinking a GPO)."""
    scope_kind, scope_id = _resolve_policy_scope(body.scope_ou_id, body.host_group_id, body.site_id)
    cp = await session.get(ConfigPolicy, policy_id)
    if cp is None:
        raise HTTPException(status_code=404, detail=f"no such config policy {policy_id}")
    cp.scope_ou_id = scope_id if scope_kind == "ou" else None
    cp.host_group_id = scope_id if scope_kind == "group" else None
    cp.site_id = scope_id if scope_kind == "site" else None
    cp.updated_at = datetime.now(timezone.utc)
    cp_path = cp.path  # read before commit: a rollback expires the instance
    try:
        await session.commit()
    except IntegrityError:
        # That scope already has a policy for this file (uq on scope+path):
        # surface a clean 409 instead of a raw 500 so the UI can explain it.
        await session.rollback()
        raise HTTPException(
            status_code=409,
            detail=f"{cp_path} already has a policy at this scope — edit that one instead of linking a second.",
        )
    return {"id": str(cp.id), "scope_ou_id": str(cp.scope_ou_id) if cp.scope_ou_id else None,
            "host_group_id": str(cp.host_group_id) if cp.host_group_id else None,
            "site_id": str(cp.site_id) if cp.site_id else None}


@router.delete("/api/v1/config-policies/{policy_id}", status_code=204)
async def delete_config_policy(
    policy_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)
) -> None:
    """Remove an OU config policy (Block K4). Member hosts keep the last-applied
    file until re-synced — deleting the policy just stops distributing it; it
    does not revert hosts (mirrors unlinking a GPO)."""
    cp = await session.get(ConfigPolicy, policy_id)
    if cp is None:
        raise HTTPException(status_code=404, detail=f"no such config policy {policy_id}")
    await session.delete(cp)
    await session.commit()


class AssignHostOUIn(BaseModel):
    ou_id: UUID | None


@router.put("/api/v1/agents/{agent_id}/ou", response_model=OUNodeOut | None)
async def assign_agent_ou(
    agent_id: UUID,
    body: AssignHostOUIn,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> OUNodeOut | None:
    """A host lives at exactly one OU (the AD model) — setting it here
    replaces any prior placement rather than adding to it. NULL un-places
    the host (root/unassigned)."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail=f"no such agent {agent_id}")
    if body.ou_id is not None:
        node = await _get_ou_or_404(session, body.ou_id)
        agent.ou_id = node.id
        await session.commit()
        return OUNodeOut.from_model(node)
    agent.ou_id = None
    await session.commit()
    return None
