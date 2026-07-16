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
    HostGroup,
    NotificationRule,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OUNode,
)
from bossman.db.session import get_session
from bossman.services.agent_client import AgentClientError
from bossman.services.compiler import affected_agent_ids, compile_host_desired_state, resolve_ou_ancestry

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


class ConfigPolicyIn(BaseModel):
    """Author a config-value policy at OU or group scope (gpedit's 'add a
    setting to a policy'). Exactly one of scope_ou_id / host_group_id is set.
    `values` is the desired key→value document for the file; a null value on a
    key enforces its absence. Persisting the policy is the authoring act; on a
    real (non-dry_run) save we also converge every reachable member host so it
    takes effect immediately, like linking a GPO."""

    scope_ou_id: UUID | None = None
    host_group_id: UUID | None = None
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
    is_ou = body.scope_ou_id is not None
    if is_ou == (body.host_group_id is not None):
        raise HTTPException(status_code=422, detail="set exactly one of scope_ou_id / host_group_id")
    if is_ou and await session.get(OUNode, body.scope_ou_id) is None:
        raise HTTPException(status_code=422, detail=f"no such OU {body.scope_ou_id}")
    if not is_ou and await session.get(HostGroup, body.host_group_id) is None:
        raise HTTPException(status_code=422, detail=f"no such host group {body.host_group_id}")

    if not body.dry_run:
        if is_ou:
            q = select(ConfigPolicy).where(ConfigPolicy.scope_ou_id == body.scope_ou_id, ConfigPolicy.path == body.path)
        else:
            q = select(ConfigPolicy).where(ConfigPolicy.host_group_id == body.host_group_id, ConfigPolicy.path == body.path)
        pol = await session.scalar(q)
        if pol is None:
            # DEFAULT_TENANT_ID may be a str or already a UUID depending on
            # import order (some modules coerce the module attribute) — str()
            # first so UUID() accepts it either way.
            pol = ConfigPolicy(
                tenant_id=UUID(str(DEFAULT_TENANT_ID)), path=body.path,
                scope_ou_id=body.scope_ou_id if is_ou else None,
                host_group_id=None if is_ou else body.host_group_id,
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
    if is_ou:
        member_ids = await affected_agent_ids(session, "ou", ou_id=body.scope_ou_id)
    else:
        member_ids = await affected_agent_ids(session, "group", host_group_id=body.host_group_id)
    applied, skipped = [], []
    for mid in member_ids:
        m = await session.get(Agent, mid)
        if m is None or not m.address:
            skipped.append(str(mid))
            continue
        try:
            await client_factory(m, settings).state_apply({"resources": [resource]}, body.dry_run)
            applied.append(m.name)
        except AgentClientError:
            skipped.append(m.name)
    return {
        "scope": "ou" if is_ou else "group",
        "scope_ou_id": str(body.scope_ou_id) if is_ou else None,
        "host_group_id": None if is_ou else str(body.host_group_id),
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
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[dict]:
    """Config policies WITH their values documents, for the Policy-console
    gpedit editor (the OU objects list only carries a label). Filter by OU or
    group scope; no filter returns all."""
    stmt = select(ConfigPolicy)
    if scope_ou_id is not None:
        stmt = stmt.where(ConfigPolicy.scope_ou_id == scope_ou_id)
    if host_group_id is not None:
        stmt = stmt.where(ConfigPolicy.host_group_id == host_group_id)
    return [
        {
            "id": str(cp.id),
            "scope_ou_id": str(cp.scope_ou_id) if cp.scope_ou_id else None,
            "host_group_id": str(cp.host_group_id) if cp.host_group_id else None,
            "path": cp.path, "type": cp.type, "format": cp.config_format,
            "separator": cp.separator, "values": cp.values or {}, "template": cp.template,
        }
        for cp in (await session.scalars(stmt)).all()
    ]


class ConfigPolicyUnsetIn(BaseModel):
    scope_ou_id: UUID | None = None
    host_group_id: UUID | None = None
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
    is_ou = body.scope_ou_id is not None
    if is_ou == (body.host_group_id is not None):
        raise HTTPException(status_code=422, detail="set exactly one of scope_ou_id / host_group_id")
    if is_ou:
        q = select(ConfigPolicy).where(ConfigPolicy.scope_ou_id == body.scope_ou_id, ConfigPolicy.path == body.path)
    else:
        q = select(ConfigPolicy).where(ConfigPolicy.host_group_id == body.host_group_id, ConfigPolicy.path == body.path)
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
