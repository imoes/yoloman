"""A group's OU must not contradict its members' OU — refused where it is created.

A host sits in exactly one OU and inheritance flows down that tree. A group can also be placed in an
OU. Nothing stopped those two from naming unrelated branches: host in /Asia, its group in /Europe.
Then two statements about the same host's place disagree, and a rule at either OU has no defined
precedence against a rule at the other — GPO orders by DEPTH ALONG ONE PATH, and sibling branches
have no such order.

The half that a naive check gets wrong is nesting: a group in /Europe whose member is in
/Europe/Latvia is consistent, because one contains the other. Refusing that would forbid the normal
way to organise a fleet, so several tests here exist purely to hold that line.
"""

import uuid

from sqlalchemy import select

from bossman.db.models import Agent, HostGroup, HostGroupMember, OUNode
from bossman.services import ou_placement
from tests.naming import owned_name

TENANT = uuid.UUID("00000000-0000-0000-0000-000000000001")


async def _ou(db_session, path: str) -> OUNode:
    """An OU at `path` ("/Europe/Latvia"); ltree_path is the dotted label form the resolver uses."""
    labels = [p for p in path.strip("/").split("/") if p]
    node = OUNode(
        id=uuid.uuid4(), tenant_id=TENANT, name=labels[-1], path="/" + "/".join(labels),
        ltree_path=".".join(labels),
    )
    db_session.add(node)
    await db_session.flush()
    return node


async def _group(db_session, ou: OUNode | None = None) -> HostGroup:
    g = HostGroup(id=uuid.uuid4(), tenant_id=TENANT, name=owned_name("grp"),
                  ou_id=ou.id if ou else None)
    db_session.add(g)
    await db_session.flush()
    return g


async def _agent(db_session, ou: OUNode | None = None) -> Agent:
    a = Agent(id=uuid.uuid4(), tenant_id=TENANT, name=owned_name("host"), token="t",
              mode="standalone", enrollment_state="enrolled", ou_id=ou.id if ou else None)
    db_session.add(a)
    await db_session.flush()
    return a


async def _join(db_session, group: HostGroup, agent: Agent) -> None:
    db_session.add(HostGroupMember(tenant_id=TENANT, host_group_id=group.id, agent_id=agent.id))
    await db_session.flush()


# ---- the contradiction ----


async def test_disjoint_branches_conflict(db_session):
    europe, asia = await _ou(db_session, "/Europe"), await _ou(db_session, "/Asia")
    group, host = await _group(db_session), await _agent(db_session, asia)
    await _join(db_session, group, host)

    conflicts = await ou_placement.conflicts_for_group_ou(db_session, group, europe.id)
    assert len(conflicts) == 1
    msg = conflicts[0].message()
    # The message must name BOTH sides and BOTH paths — either one could be the thing to change, and
    # a refusal that does not say which is which forces the reader to guess.
    assert group.name in msg and host.name in msg
    assert "/Europe" in msg and "/Asia" in msg


async def test_the_membership_side_refuses_the_same_thing(db_session):
    """Guarding only the group endpoint would leave this one as a back door."""
    europe, asia = await _ou(db_session, "/Europe"), await _ou(db_session, "/Asia")
    group, host = await _group(db_session, europe), await _agent(db_session, asia)
    conflicts = await ou_placement.conflicts_for_membership(db_session, host, {group.id})
    assert len(conflicts) == 1
    assert "/Europe" in conflicts[0].message() and "/Asia" in conflicts[0].message()


async def test_every_conflicting_host_is_named(db_session):
    """One round trip should reveal the whole scale, not the first offender."""
    europe, asia = await _ou(db_session, "/Europe"), await _ou(db_session, "/Asia")
    group = await _group(db_session)
    for _ in range(3):
        await _join(db_session, group, await _agent(db_session, asia))

    conflicts = await ou_placement.conflicts_for_group_ou(db_session, group, europe.id)
    assert len(conflicts) == 3
    detail = ou_placement.as_detail(conflicts)
    assert detail.startswith("3 member hosts")
    for c in conflicts:
        assert c.host_name in detail


# ---- what must NOT be refused ----


async def test_a_child_ou_is_not_a_conflict(db_session):
    """The line this whole check must not cross: /Europe governing /Europe/Latvia is the design."""
    europe = await _ou(db_session, "/Europe")
    latvia = await _ou(db_session, "/Europe/Latvia")
    group, host = await _group(db_session), await _agent(db_session, latvia)
    await _join(db_session, group, host)
    assert await ou_placement.conflicts_for_group_ou(db_session, group, europe.id) == []


async def test_a_parent_ou_is_not_a_conflict_either(db_session):
    """The other direction: the group deeper than the host still lies on one path."""
    europe = await _ou(db_session, "/Europe")
    latvia = await _ou(db_session, "/Europe/Latvia")
    group, host = await _group(db_session), await _agent(db_session, europe)
    await _join(db_session, group, host)
    assert await ou_placement.conflicts_for_group_ou(db_session, group, latvia.id) == []


async def test_the_same_ou_is_not_a_conflict(db_session):
    europe = await _ou(db_session, "/Europe")
    group, host = await _group(db_session), await _agent(db_session, europe)
    await _join(db_session, group, host)
    assert await ou_placement.conflicts_for_group_ou(db_session, group, europe.id) == []


async def test_a_sibling_with_a_shared_name_prefix_is_still_a_conflict(db_session):
    """/Europe must not be read as containing /Europe2 — the same prefix trap as host names.
    Without the dot in the ancestor test this passes silently and the guard has a hole."""
    europe = await _ou(db_session, "/Europe")
    europe2 = await _ou(db_session, "/Europe2")
    group, host = await _group(db_session), await _agent(db_session, europe2)
    await _join(db_session, group, host)
    assert len(await ou_placement.conflicts_for_group_ou(db_session, group, europe.id)) == 1


async def test_an_unplaced_host_never_conflicts(db_session):
    """"Not in an OU" is a state, not a competing claim — it must not block placing the group."""
    europe = await _ou(db_session, "/Europe")
    group, host = await _group(db_session), await _agent(db_session, None)
    await _join(db_session, group, host)
    assert await ou_placement.conflicts_for_group_ou(db_session, group, europe.id) == []


async def test_clearing_the_group_placement_is_always_allowed(db_session):
    """Removing a placement cannot create a contradiction, so it must never be refused — otherwise
    an operator who got into this state could not get out of it."""
    asia = await _ou(db_session, "/Asia")
    group, host = await _group(db_session), await _agent(db_session, asia)
    await _join(db_session, group, host)
    assert await ou_placement.conflicts_for_group_ou(db_session, group, None) == []


async def test_a_group_with_no_members_can_go_anywhere(db_session):
    europe = await _ou(db_session, "/Europe")
    group = await _group(db_session)
    assert await ou_placement.conflicts_for_group_ou(db_session, group, europe.id) == []


async def test_an_unplaced_group_does_not_constrain_membership(db_session):
    asia = await _ou(db_session, "/Asia")
    group, host = await _group(db_session), await _agent(db_session, asia)
    assert await ou_placement.conflicts_for_membership(db_session, host, {group.id}) == []


async def test_the_ancestor_test_itself(db_session):
    """Unit-level, because every case above rests on it."""
    rel = ou_placement._is_related
    assert rel("Europe", "Europe") is True
    assert rel("Europe.Latvia", "Europe") is True
    assert rel("Europe", "Europe.Latvia") is True
    assert rel("Europe", "Asia") is False
    assert rel("Europe", "Europe2") is False      # the prefix trap
    assert rel("Europe2", "Europe") is False
    assert rel(None, "Europe") is True            # unknown cannot contradict
    assert rel("", "Europe") is True
