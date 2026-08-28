"""The ONE place that writes host-group membership.

Membership was stored twice, and the two stores drifted apart — measured, not suspected:
`PUT /host-groups/{id}/members` wrote only `host_group_members`, while rule matching reads
`agents.groups` (services/scope.py, services/monitoring.py). A host added through the group
editor reported 1 member on the group and an empty `groups` array on the host, and a
group-scoped CheckRule did not apply to it. The UI claimed membership, the monitoring engine
disagreed, and nothing said so.

That split was not an accident: `HostGroup`'s own docstring says the first-class group arrived
"distinct from the legacy flat agents.groups string list, which stays untouched in L1". It was
an unfinished migration — the new table was added, the reader was never moved.

The resolution here, rather than moving the reader:

* **`host_group_members` is the source of truth.** Membership is a relation between two rows,
  and only a row with foreign keys cannot dangle.
* **`agents.groups` is a projection of it**, recomputed in the same transaction by
  `project_agent_groups`. It stays because matching needs NAMES and because a group name is
  deliberately a PATH — "Europe" also governs "Europe/Latvia" (services/scope.py) — which an id
  cannot express.
* Every write goes through this module, so there is one derivation and not three writers.

A name with no `host_groups` row is CREATED rather than refused. The array has always accepted
any string, so refusing would remove an existing capability; creating the row instead makes the
source of truth complete. The alternative — keeping name-only members — is exactly the state
this module exists to end.
"""

from __future__ import annotations

import uuid as _uuid
from datetime import datetime, timezone

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, HostGroup, HostGroupMember

#: The single-tenant default, as used by api/host_groups.py.
DEFAULT_TENANT_ID = _uuid.UUID("00000000-0000-0000-0000-000000000001")


async def _live_groups_by_name(session: AsyncSession, names: list[str]) -> dict[str, HostGroup]:
    if not names:
        return {}
    rows = (
        await session.scalars(
            select(HostGroup).where(HostGroup.name.in_(names), HostGroup.deleted_at.is_(None))
        )
    ).all()
    return {g.name: g for g in rows}


async def resolve_or_create(session: AsyncSession, names: list[str]) -> list[HostGroup]:
    """The groups for these names, creating any that do not exist yet.

    Order and duplicates from the caller are normalised away: membership is a set.
    """
    wanted = [n.strip() for n in names if n and n.strip()]
    wanted = list(dict.fromkeys(wanted))
    existing = await _live_groups_by_name(session, wanted)
    out: list[HostGroup] = []
    for name in wanted:
        group = existing.get(name)
        if group is None:
            group = HostGroup(id=_uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, name=name, description="")
            session.add(group)
            await session.flush()  # need the id for the membership row below
        out.append(group)
    return out


async def project_agent_groups(session: AsyncSession, agent: Agent) -> None:
    """Recompute one host's `groups` array from the membership rows.

    Sorted, so the array is a function of the membership and not of insertion order — two
    hosts in the same groups then have equal arrays, which makes the projection comparable
    and any drift visible.
    """
    names = (
        await session.scalars(
            select(HostGroup.name)
            .join(HostGroupMember, HostGroupMember.host_group_id == HostGroup.id)
            .where(HostGroupMember.agent_id == agent.id, HostGroup.deleted_at.is_(None))
        )
    ).all()
    agent.groups = sorted(set(names))


async def set_agent_groups(session: AsyncSession, agent: Agent, names: list[str]) -> list[HostGroup]:
    """Replace one host's membership, by group NAME (the host-detail editor's shape)."""
    groups = await resolve_or_create(session, names)
    await session.execute(delete(HostGroupMember).where(HostGroupMember.agent_id == agent.id))
    await session.flush()
    for group in groups:
        session.add(
            HostGroupMember(
                id=_uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, host_group_id=group.id, agent_id=agent.id
            )
        )
    await session.flush()
    await project_agent_groups(session, agent)
    return groups


async def adopt_projection(session: AsyncSession, agent: Agent) -> None:
    """Turn names that sit only in `agents.groups` into real memberships.

    Every host whose array was written before this module existed — by the old endpoints, by a
    fixture, by an enrollment payload — has names with no membership row. Projecting such a
    host from the table alone would DELETE those groups, silently, on the first unrelated edit;
    a test caught exactly that (a host created with groups=["Europe"] lost it when "prod" was
    added). So the array is adopted first: it is what actually drove matching, therefore it is
    the intent, and a name without a row gets one — the same rule `resolve_or_create` applies
    to names a caller passes.

    Idempotent: once adopted, the array and the table agree and this is a no-op.
    """
    names = [n for n in (agent.groups or []) if n and n.strip()]
    if not names:
        return
    groups = await resolve_or_create(session, names)
    have = set(
        (
            await session.scalars(
                select(HostGroupMember.host_group_id).where(HostGroupMember.agent_id == agent.id)
            )
        ).all()
    )
    added = False
    for group in groups:
        if group.id not in have:
            session.add(
                HostGroupMember(
                    id=_uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, host_group_id=group.id, agent_id=agent.id
                )
            )
            added = True
    if added:
        await session.flush()


async def add_agent_groups(session: AsyncSession, agent: Agent, names: list[str]) -> None:
    """Add memberships, leaving the existing ones alone (the bulk editor's "add")."""
    await adopt_projection(session, agent)
    groups = await resolve_or_create(session, names)
    have = set(
        (
            await session.scalars(
                select(HostGroupMember.host_group_id).where(HostGroupMember.agent_id == agent.id)
            )
        ).all()
    )
    for group in groups:
        if group.id not in have:
            session.add(
                HostGroupMember(
                    id=_uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, host_group_id=group.id, agent_id=agent.id
                )
            )
    await session.flush()
    await project_agent_groups(session, agent)


async def remove_agent_groups(session: AsyncSession, agent: Agent, names: list[str]) -> None:
    """Remove memberships by group name. Names the host is not in are ignored — removing
    something that is not there is not an error, it is already the requested state."""
    # Adopt first, or removing one name would also drop every not-yet-adopted name with it.
    await adopt_projection(session, agent)
    groups = await _live_groups_by_name(session, [n.strip() for n in names if n and n.strip()])
    ids = [g.id for g in groups.values()]
    if ids:
        await session.execute(
            delete(HostGroupMember).where(
                HostGroupMember.agent_id == agent.id, HostGroupMember.host_group_id.in_(ids)
            )
        )
        await session.flush()
    await project_agent_groups(session, agent)


async def set_group_members(session: AsyncSession, group: HostGroup, agent_ids: list) -> None:
    """Replace one group's membership, by agent id (the group editor's shape).

    Order matters and a test proved it: adoption runs FIRST, while the array still describes
    the pre-change state. Adopting afterwards would re-create the very membership this call
    just removed — the loser's array still names the group at that moment, so "adopt what the
    array says" would undo the removal. Adopting first captures the hosts' OTHER groups; the
    delete then affects only this group.
    """
    before = set(
        (
            await session.scalars(
                select(HostGroupMember.agent_id).where(HostGroupMember.host_group_id == group.id)
            )
        ).all()
    )
    after = list(dict.fromkeys(agent_ids))

    # 1. Adopt, so a host's not-yet-adopted groups survive this edit.
    for agent_id in before | set(after):
        agent = await session.get(Agent, agent_id)
        if agent is not None:
            await adopt_projection(session, agent)

    # 2. Replace THIS group's membership.
    await session.execute(delete(HostGroupMember).where(HostGroupMember.host_group_id == group.id))
    await session.flush()
    for agent_id in after:
        session.add(
            HostGroupMember(
                id=_uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, host_group_id=group.id, agent_id=agent_id
            )
        )
    await session.flush()

    # 3. Re-project everyone who gained OR lost it — no adoption here, or step 2 is undone.
    for agent_id in before | set(after):
        agent = await session.get(Agent, agent_id)
        if agent is not None:
            await project_agent_groups(session, agent)


async def reproject_group(session: AsyncSession, group_id) -> None:
    """Re-project every member of one group — used after a rename, where the membership is
    unchanged but the projected NAME is not."""
    agent_ids = (
        await session.scalars(
            select(HostGroupMember.agent_id).where(HostGroupMember.host_group_id == group_id)
        )
    ).all()
    for agent_id in agent_ids:
        agent = await session.get(Agent, agent_id)
        if agent is not None:
            await project_agent_groups(session, agent)


async def backfill_from_projection(session: AsyncSession) -> dict[str, int]:
    """One-time repair for hosts whose `groups` array names a group they are not a member of.

    Both stores were written independently for a while, so either can hold what the other
    lacks. The array is treated as the intent here (it is what actually drove matching), so
    its names become real memberships; afterwards the projection is rebuilt from the table and
    the two agree by construction.

    Returns counts for the log — a repair that reports nothing cannot be verified.
    """
    created_groups = 0
    added_members = 0
    reprojected = 0
    agents = (await session.scalars(select(Agent))).all()
    for agent in agents:
        names = [n for n in (agent.groups or []) if n and n.strip()]
        if names:
            known = await _live_groups_by_name(session, names)
            missing = [n for n in names if n not in known]
            groups = await resolve_or_create(session, names)
            created_groups += len(missing)
            have = set(
                (
                    await session.scalars(
                        select(HostGroupMember.host_group_id).where(HostGroupMember.agent_id == agent.id)
                    )
                ).all()
            )
            for group in groups:
                if group.id not in have:
                    session.add(
                        HostGroupMember(
                            id=_uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID,
                            host_group_id=group.id, agent_id=agent.id,
                        )
                    )
                    added_members += 1
            await session.flush()
        before = list(agent.groups or [])
        await project_agent_groups(session, agent)
        if list(agent.groups) != before:
            reprojected += 1
    return {"groups_created": created_groups, "members_added": added_members, "hosts_reprojected": reprojected}


def touch(group: HostGroup) -> None:
    """Bump updated_at on a group the caller is changing."""
    group.updated_at = datetime.now(timezone.utc)


# ---------------------------------------------------------------------------
# Renaming a group


class RenameCollision(ValueError):
    """The rename would produce a name that already belongs to another group."""


async def rename_group(session: AsyncSession, group: HostGroup, new_name: str) -> dict[str, int]:
    """Rename a group and carry every reference with it, in one transaction.

    A group name is not a label, it is the REFERENCE: `check_rules.scope_value`,
    `notification_rules.scope_value`, `template_links.host_group` and the projected
    `agents.groups` all hold the name, and matching is path-based on it ("Europe" also governs
    "Europe/Latvia", services/scope.py). Renaming only `host_groups.name` therefore left every
    rule pointing at a name that no longer existed — measured: a group-scoped rule silently
    stopped applying to every host, with nothing reporting it.

    Path children come along: renaming "Europe" turns the separate group row "Europe/Latvia"
    into "NewName/Latvia", because the child's parentage IS the prefix. Leaving them would
    detach the whole subtree from the group it belongs to.

    Returns per-table counts, so the caller can say what it changed instead of claiming success.
    """
    from bossman.db.models import CheckRule, NotificationRule, TemplateLink

    old = group.name
    new = new_name.strip()
    if not new:
        raise ValueError("name is required")
    if new == old:
        return {}

    # Every group row whose name is `old` or starts with "old/" — self plus the subtree.
    affected = (
        await session.scalars(
            select(HostGroup).where(
                HostGroup.deleted_at.is_(None),
                (HostGroup.name == old) | (HostGroup.name.startswith(f"{old}/")),
            )
        )
    ).all()
    mapping = {g.name: new + g.name[len(old):] for g in affected}

    # A collision must be refused BEFORE anything is written: the unique constraint would
    # otherwise abort mid-cascade, and the caller could not tell which half had applied.
    taken = (
        await session.scalars(
            select(HostGroup.name).where(
                HostGroup.deleted_at.is_(None),
                HostGroup.name.in_(list(mapping.values())),
                HostGroup.id.notin_([g.id for g in affected]),
            )
        )
    ).all()
    if taken:
        raise RenameCollision(f"a host group named {sorted(taken)[0]!r} already exists")

    counts = {"groups": 0, "check_rules": 0, "notification_rules": 0, "template_links": 0, "hosts": 0}
    for g in affected:
        target = mapping[g.name]
        source = g.name
        g.name = target
        touch(g)
        counts["groups"] += 1

        rules = (
            await session.scalars(
                select(CheckRule).where(CheckRule.scope_type == "group", CheckRule.scope_value == source)
            )
        ).all()
        for rule in rules:
            rule.scope_value = target
        counts["check_rules"] += len(rules)

        notes = (
            await session.scalars(
                select(NotificationRule).where(
                    NotificationRule.scope_type == "group", NotificationRule.scope_value == source
                )
            )
        ).all()
        for note in notes:
            note.scope_value = target
        counts["notification_rules"] += len(notes)

        links = (await session.scalars(select(TemplateLink).where(TemplateLink.host_group == source))).all()
        for link in links:
            link.host_group = target
        counts["template_links"] += len(links)

    await session.flush()
    # The projection holds names too, so every member of every renamed group is rebuilt.
    seen: set = set()
    for g in affected:
        ids = (
            await session.scalars(
                select(HostGroupMember.agent_id).where(HostGroupMember.host_group_id == g.id)
            )
        ).all()
        for agent_id in ids:
            if agent_id in seen:
                continue
            seen.add(agent_id)
            agent = await session.get(Agent, agent_id)
            if agent is not None:
                await project_agent_groups(session, agent)
    counts["hosts"] = len(seen)
    return counts
