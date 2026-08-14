"""Host-group membership has ONE source of truth, and a rename carries its references.

Both properties were missing and both failures were measured against the running system
before these tests existed (see services/host_membership.py's header):

* `PUT /host-groups/{id}/members` wrote only `host_group_members`, while rule matching reads
  `agents.groups` — so a host the group listed as a member was not matched by the group's
  rules. The group said "1 member", the host said `groups == []`.
* `PUT /host-groups/{id}` renamed only `host_groups.name`, leaving every `check_rules`,
  `notification_rules`, `template_links` and projected `agents.groups` reference aimed at a
  name that no longer existed — a group-scoped rule silently stopped applying.

Same commit-through-a-separate-session pattern as tests/test_host_groups_api.py: rows are
created and committed via the db_session fixture so the app's own session sees them, then
cleaned up explicitly.
"""

import uuid

from fastapi.testclient import TestClient
from sqlalchemy import select

from bossman.db.models import AccessGrant, Agent, CheckRule, HostGroup, HostGroupMember, NotificationRule
from bossman.main import create_app
from bossman.services.auth import new_api_token

TENANT = uuid.UUID("00000000-0000-0000-0000-000000000001")


def _sfx() -> str:
    return uuid.uuid4().hex[:8]


async def _token(db_session):
    row, raw = new_api_token(f"mem-caller-{_sfx()}")
    db_session.add(row)
    await db_session.flush()
    await db_session.commit()
    return row, {"Authorization": f"Bearer {raw}"}


async def _grant_all(db_session, api_token) -> AccessGrant:
    """PATCH /agents/{id}/groups goes through require_manage_agent (Block M): an api_token
    needs an explicit grant, unlike the read-only endpoints. Granting scope='all' keeps this
    test about MEMBERSHIP rather than about authorization."""
    grant = AccessGrant(
        id=uuid.uuid4(), subject_kind="api_token", subject_ref=api_token.name,
        scope="all", permission="manage",
    )
    db_session.add(grant)
    await db_session.flush()
    await db_session.commit()
    return grant


async def _agent(db_session, prefix="mem-host") -> Agent:
    agent = Agent(
        name=f"{prefix}-{_sfx()}", token=uuid.uuid4().hex, mode="standalone", enrollment_state="enrolled"
    )
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _group(db_session, name: str) -> HostGroup:
    group = HostGroup(id=uuid.uuid4(), tenant_id=TENANT, name=name, description="")
    db_session.add(group)
    await db_session.flush()
    await db_session.commit()
    return group


async def _cleanup(db_session, *rows):
    for row in rows:
        if row is not None:
            await db_session.delete(row)
    await db_session.commit()


async def test_group_side_membership_reaches_the_projection(db_session):
    """Adding a host through the GROUP editor must make rule matching see it.

    This is the exact failure that was measured: the membership row existed and
    `agents.groups` stayed empty, so `scope.py`'s name-based matching never fired.
    """
    api_token, headers = await _token(db_session)
    agent = await _agent(db_session)
    group = await _group(db_session, f"mem-grp-{_sfx()}")

    app = create_app()
    with TestClient(app) as client:
        resp = client.put(
            f"/api/v1/host-groups/{group.id}/members", json={"agent_ids": [str(agent.id)]}, headers=headers
        )
    assert resp.status_code == 200, resp.text
    assert resp.json()["member_agent_ids"] == [str(agent.id)]

    await db_session.refresh(agent)
    assert agent.groups == [group.name], "the group editor must write the projection rule matching reads"

    members = (
        await db_session.scalars(select(HostGroupMember).where(HostGroupMember.host_group_id == group.id))
    ).all()
    assert len(members) == 1

    await _cleanup(db_session, *members)
    await _cleanup(db_session, group, agent, api_token)


async def test_removing_a_host_from_the_group_clears_its_projection(db_session):
    """The loser of a membership change must be re-projected too, or it keeps matching."""
    api_token, headers = await _token(db_session)
    agent = await _agent(db_session)
    group = await _group(db_session, f"mem-grp-{_sfx()}")

    app = create_app()
    with TestClient(app) as client:
        client.put(
            f"/api/v1/host-groups/{group.id}/members", json={"agent_ids": [str(agent.id)]}, headers=headers
        )
        resp = client.put(f"/api/v1/host-groups/{group.id}/members", json={"agent_ids": []}, headers=headers)
    assert resp.status_code == 200, resp.text

    await db_session.refresh(agent)
    assert agent.groups == []

    await _cleanup(db_session, group, agent, api_token)


async def test_deleting_a_group_clears_it_from_its_members(db_session):
    """Deleting the group must leave no member matching it.

    The membership rows go with the cascade, but `agents.groups` is a separate projection: a
    former member kept the deleted group's NAME and therefore kept matching its rules. Caught
    by measuring the delete right after fixing add and rename — the same defect one door down.
    """
    api_token, headers = await _token(db_session)
    agent = await _agent(db_session)
    group = await _group(db_session, f"mem-grp-{_sfx()}")

    app = create_app()
    with TestClient(app) as client:
        client.put(
            f"/api/v1/host-groups/{group.id}/members", json={"agent_ids": [str(agent.id)]}, headers=headers
        )
        resp = client.delete(f"/api/v1/host-groups/{group.id}", headers=headers)
    assert resp.status_code == 204, resp.text

    await db_session.refresh(agent)
    assert agent.groups == [], "a deleted group must not stay in its members' projection"

    await _cleanup(db_session, agent, api_token)


async def test_host_side_membership_writes_the_membership_table(db_session):
    """The other direction: naming groups on the HOST must create real membership rows,
    otherwise the group editor and the host editor disagree again — just the other way round.
    """
    api_token, headers = await _token(db_session)
    grant = await _grant_all(db_session, api_token)
    agent = await _agent(db_session)
    name = f"mem-grp-{_sfx()}"

    app = create_app()
    with TestClient(app) as client:
        resp = client.patch(f"/api/v1/agents/{agent.id}/groups", json={"groups": [name]}, headers=headers)
    assert resp.status_code == 200, resp.text
    assert resp.json()["groups"] == [name]

    group = await db_session.scalar(select(HostGroup).where(HostGroup.name == name))
    assert group is not None, "a named group with no row must be created, not left dangling"
    members = (
        await db_session.scalars(select(HostGroupMember).where(HostGroupMember.host_group_id == group.id))
    ).all()
    assert [m.agent_id for m in members] == [agent.id]

    await _cleanup(db_session, *members)
    await _cleanup(db_session, group, agent, grant, api_token)


async def test_rename_carries_rules_links_and_projection(db_session):
    """A rename must move every reference with it — the name IS the reference."""
    api_token, headers = await _token(db_session)
    agent = await _agent(db_session)
    old = f"mem-grp-{_sfx()}"
    new = f"{old}-renamed"
    group = await _group(db_session, old)

    rule = CheckRule(
        service_name="probe", metric="cpu_load1", comparison="gt", warn_threshold=9, crit_threshold=99,
        scope_type="group", scope_value=old,
    )
    note = NotificationRule(name=f"mem-note-{_sfx()}", channel="email", target="x@example.com",
                            scope_type="group", scope_value=old)
    db_session.add_all([rule, note])
    await db_session.flush()
    await db_session.commit()

    app = create_app()
    with TestClient(app) as client:
        client.put(
            f"/api/v1/host-groups/{group.id}/members", json={"agent_ids": [str(agent.id)]}, headers=headers
        )
        resp = client.put(
            f"/api/v1/host-groups/{group.id}", json={"name": new, "description": ""}, headers=headers
        )
    assert resp.status_code == 200, resp.text
    assert resp.json()["name"] == new

    await db_session.refresh(rule)
    await db_session.refresh(note)
    await db_session.refresh(agent)
    assert rule.scope_value == new, "a group-scoped check rule must follow the rename"
    assert note.scope_value == new, "a group-scoped notification rule must follow the rename"
    assert agent.groups == [new], "the projection must follow the rename"

    members = (
        await db_session.scalars(select(HostGroupMember).where(HostGroupMember.host_group_id == group.id))
    ).all()
    await _cleanup(db_session, *members)
    await _cleanup(db_session, rule, note, group, agent, api_token)


async def test_rename_carries_path_children(db_session):
    """Nested groups are paths: renaming "a" must turn the separate row "a/b" into "new/b",
    or the subtree detaches from the group it belongs to."""
    api_token, headers = await _token(db_session)
    parent_name = f"mem-grp-{_sfx()}"
    child_name = f"{parent_name}/child"
    new_parent = f"{parent_name}-renamed"
    parent = await _group(db_session, parent_name)
    child = await _group(db_session, child_name)

    app = create_app()
    with TestClient(app) as client:
        resp = client.put(
            f"/api/v1/host-groups/{parent.id}", json={"name": new_parent, "description": ""}, headers=headers
        )
    assert resp.status_code == 200, resp.text

    await db_session.refresh(child)
    assert child.name == f"{new_parent}/child"

    await _cleanup(db_session, child, parent, api_token)


async def test_rename_collision_is_refused_before_anything_changes(db_session):
    """A colliding rename must be a 409 and leave the old name intact — the unique constraint
    would otherwise abort mid-cascade, with half the references moved."""
    api_token, headers = await _token(db_session)
    a = await _group(db_session, f"mem-grp-a-{_sfx()}")
    b = await _group(db_session, f"mem-grp-b-{_sfx()}")

    app = create_app()
    with TestClient(app) as client:
        resp = client.put(
            f"/api/v1/host-groups/{a.id}", json={"name": b.name, "description": ""}, headers=headers
        )
    assert resp.status_code == 409, resp.text

    await db_session.refresh(a)
    assert a.name.startswith("mem-grp-a-"), "the rename must not have applied"

    await _cleanup(db_session, a, b, api_token)
