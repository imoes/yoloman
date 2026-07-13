"""Target resolution for multi-host deployments (services.targets)."""

from uuid import uuid4

from bossman.db.models import Agent, HostGroup, HostGroupMember, OUNode
from bossman.services.targets import TargetSpec, resolve_targets

TENANT = "00000000-0000-0000-0000-000000000001"


def _sfx():
    return uuid4().hex[:8]


async def _ou(db_session, name, parent=None):
    s = _sfx()
    path = (parent.path if parent else "") + "/" + f"{name}-{s}"
    n = OUNode(id=uuid4(), tenant_id=TENANT, parent_id=(parent.id if parent else None), name=f"{name}-{s}",
               path=path, ltree_path=path.strip("/").replace("/", "."))
    db_session.add(n)
    await db_session.flush()
    return n


async def _agent(db_session, *, ou=None, tags=None):
    a = Agent(id=uuid4(), name=f"tgt-{_sfx()}", token="t", tenant_id=TENANT,
              ou_id=(ou.id if ou else None), tags=tags or {})
    db_session.add(a)
    await db_session.flush()
    return a


async def _group(db_session, *members):
    g = HostGroup(id=uuid4(), tenant_id=TENANT, name=f"g-{_sfx()}", ou_id=None)
    db_session.add(g)
    await db_session.flush()
    for m in members:
        db_session.add(HostGroupMember(id=uuid4(), tenant_id=TENANT, host_group_id=g.id, agent_id=m.id))
    await db_session.flush()
    return g


async def test_resolve_by_hostname_reports_unknown(db_session):
    a = await _agent(db_session)
    res = await resolve_targets(db_session, TENANT, TargetSpec(hostnames=[a.name, "does-not-exist"]))
    assert [x.name for x in res.agents] == [a.name]
    assert res.unknown_hostnames == ["does-not-exist"]


async def test_resolve_by_group(db_session):
    a1, a2 = await _agent(db_session), await _agent(db_session)
    g = await _group(db_session, a1, a2)
    res = await resolve_targets(db_session, TENANT, TargetSpec(group_ids=[g.id]))
    assert {x.id for x in res.agents} == {a1.id, a2.id}


async def test_resolve_by_ou_subtree(db_session):
    root = await _ou(db_session, "Prod")
    child = await _ou(db_session, "Web", parent=root)
    a_root = await _agent(db_session, ou=root)
    a_child = await _agent(db_session, ou=child)
    res = await resolve_targets(db_session, TENANT, TargetSpec(ou_ids=[root.id]))
    assert {x.id for x in res.agents} == {a_root.id, a_child.id}  # subtree included


async def test_resolve_by_tag_and_dedup(db_session):
    a = await _agent(db_session, tags={"env": "prod"})
    await _agent(db_session, tags={"env": "dev"})
    # named twice (id + tag) → must dedup to one
    res = await resolve_targets(db_session, TENANT, TargetSpec(agent_ids=[a.id], tags={"env": "prod"}))
    assert [x.id for x in res.agents] == [a.id]


async def test_resolve_tag_presence_only(db_session):
    a = await _agent(db_session, tags={"role": "db"})
    await _agent(db_session, tags={"other": "x"})
    res = await resolve_targets(db_session, TENANT, TargetSpec(tags={"role": None}))
    assert [x.id for x in res.agents] == [a.id]
