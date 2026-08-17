"""Is a host group's OU placement consistent with its members' own OU?

THE ANOMALY. A host sits in exactly one OU (`agents.ou_id`) and inheritance flows down that tree.
A host GROUP can also be placed in an OU (`host_groups.ou_id`). Nothing stops those two from
pointing at unrelated branches: host `db01` in `/Asia`, its group `webservers` in `/Europe`. Then
two statements about the same host's place in the tree disagree, and a rule written at either OU has
no defined relationship to the other — there is no precedence between two sibling branches, because
GPO's precedence is depth along ONE path.

WHAT IS NOT A CONFLICT, and this is the part a naive check gets wrong: nesting. A group in `/Europe`
whose member sits in `/Europe/Latvia` is perfectly consistent — one is an ancestor of the other, so
both lie on a single inheritance path and depth decides, exactly as designed. Refusing that would
block the normal way of organising a fleet. Only DISJOINT branches contradict.

A host with no OU at all (`ou_id IS NULL`) never conflicts either: "not placed" is a state, not a
competing claim.

WHY THIS IS A REFUSAL AND POLICY LAYERING IS NOT. Two layers touching one setting is not an error —
it is the whole point of layering, and precedence resolves it. Two OU placements that cannot be
ordered is a different thing: there is nothing to resolve it WITH. So the contradiction is refused
where it is created (group management), rather than being reported later as a mystery.
"""

from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, HostGroup, HostGroupMember, OUNode


@dataclass
class PlacementConflict:
    """One host whose own OU is on a different branch than its group's OU."""

    group_name: str
    group_ou_path: str
    host_name: str
    host_ou_path: str

    def message(self) -> str:
        """The exact sentence an operator needs: both names, both paths, and why it is refused.

        Not "invalid placement" — a refusal without its reason forces the reader to guess which of
        the two sides to change, and either could be the right one.
        """
        return (
            f"host group {self.group_name!r} is in OU {self.group_ou_path!r}, but its member "
            f"{self.host_name!r} is in OU {self.host_ou_path!r}. Those OUs are on different "
            f"branches, so a rule at one has no defined precedence against a rule at the other. "
            f"Move the host into {self.group_ou_path!r} (or a child of it), or place the group at "
            f"an OU that contains {self.host_ou_path!r}."
        )


def _is_related(a: str | None, b: str | None) -> bool:
    """Do two ltree paths lie on one inheritance path (equal, or one an ancestor of the other)?

    String prefix on the label path, with the dot appended so `Europe` does not "contain"
    `Europe2` — the same trap as matching host names by prefix.
    """
    if not a or not b:
        return True  # unknown placement cannot contradict anything
    if a == b:
        return True
    return a.startswith(b + ".") or b.startswith(a + ".")


async def _ou_paths(session: AsyncSession, ou_ids: set[UUID]) -> dict[UUID, tuple[str, str]]:
    """{ou_id: (human path, ltree path)} for the ids given."""
    if not ou_ids:
        return {}
    rows = (
        await session.scalars(select(OUNode).where(OUNode.id.in_(list(ou_ids))))
    ).all()
    return {n.id: (n.path or "", str(n.ltree_path or "")) for n in rows}


async def conflicts_for_group_ou(
    session: AsyncSession, group: HostGroup, new_ou_id: UUID | None,
) -> list[PlacementConflict]:
    """Placing `group` at `new_ou_id` — which of its members would contradict it?

    Called BEFORE the write, with the prospective OU rather than the stored one, so the refusal
    happens instead of the change and not after it.
    """
    if new_ou_id is None:
        return []  # removing the placement can never create a contradiction
    member_ids = (
        await session.scalars(
            select(HostGroupMember.agent_id).where(HostGroupMember.host_group_id == group.id)
        )
    ).all()
    if not member_ids:
        return []
    agents = (
        await session.scalars(select(Agent).where(Agent.id.in_(list(member_ids))))
    ).all()
    return await _compare(session, group.name, new_ou_id, list(agents))


async def conflicts_for_membership(
    session: AsyncSession, agent: Agent, group_ids: set[UUID],
) -> list[PlacementConflict]:
    """Putting `agent` into these groups — which of them contradict the host's own OU?

    The mirror of conflicts_for_group_ou: the same contradiction can be created from either side, so
    both sides check. Guarding only the group side would leave the membership endpoint as an open
    back door into exactly the state the other endpoint refuses.
    """
    if agent.ou_id is None or not group_ids:
        return []
    groups = (
        await session.scalars(select(HostGroup).where(HostGroup.id.in_(list(group_ids))))
    ).all()
    placed = [g for g in groups if g.ou_id is not None]
    if not placed:
        return []
    paths = await _ou_paths(session, {agent.ou_id} | {g.ou_id for g in placed if g.ou_id})
    host_human, host_ltree = paths.get(agent.ou_id, ("", ""))
    out: list[PlacementConflict] = []
    for g in placed:
        g_human, g_ltree = paths.get(g.ou_id, ("", ""))  # type: ignore[arg-type]
        if not _is_related(host_ltree, g_ltree):
            out.append(PlacementConflict(
                group_name=g.name, group_ou_path=g_human,
                host_name=agent.name or str(agent.id), host_ou_path=host_human,
            ))
    return out


async def _compare(
    session: AsyncSession, group_name: str, group_ou_id: UUID, agents: list[Agent],
) -> list[PlacementConflict]:
    placed = [a for a in agents if a.ou_id is not None]
    if not placed:
        return []
    paths = await _ou_paths(session, {group_ou_id} | {a.ou_id for a in placed if a.ou_id})
    g_human, g_ltree = paths.get(group_ou_id, ("", ""))
    out: list[PlacementConflict] = []
    for a in placed:
        h_human, h_ltree = paths.get(a.ou_id, ("", ""))  # type: ignore[arg-type]
        if not _is_related(h_ltree, g_ltree):
            out.append(PlacementConflict(
                group_name=group_name, group_ou_path=g_human,
                host_name=a.name or str(a.id), host_ou_path=h_human,
            ))
    return out


def as_detail(conflicts: list[PlacementConflict]) -> str:
    """One HTTP detail string for however many conflicts there are.

    Every conflicting host is named, not just the first: an operator who moves one group and gets
    told about one host would fix it and hit the next refusal, learning the scale one round trip at
    a time.
    """
    if len(conflicts) == 1:
        return conflicts[0].message()
    lead = f"{len(conflicts)} member hosts contradict this OU placement:"
    return lead + "".join(f"\n  · {c.message()}" for c in conflicts)
