"""Block G9-P2 — the check-assignment GPO resolver (host > group > OU,
params merged inherited→specific). Real DB via db_session; the resolver
only reads, so the fixture rollback cleans up."""

from uuid import uuid4

from bossman.db.models import Agent, CheckAssignment, HostGroup, HostGroupMember, OUNode
from bossman.services.check_assignments import resolve_host_checks

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


async def _agent(db_session, ou=None):
    a = Agent(id=uuid4(), name=f"host-{_sfx()}", token="t", tenant_id=TENANT, ou_id=(ou.id if ou else None))
    db_session.add(a)
    await db_session.flush()
    return a


async def _assign(db_session, check_name, scope_type, *, ou=None, group=None, agent=None, params=None):
    a = CheckAssignment(
        id=uuid4(), tenant_id=TENANT, check_name=check_name, scope_type=scope_type,
        ou_id=(ou.id if ou else None), host_group_id=(group.id if group else None),
        agent_id=(agent.id if agent else None), parameters=params or {}, enabled=True,
    )
    db_session.add(a)
    await db_session.flush()
    return a


async def test_precedence_host_over_ou_over_group(db_session):
    root = await _ou(db_session, "Databases")
    child = await _ou(db_session, "Prod", parent=root)
    agent = await _agent(db_session, child)
    grp = HostGroup(id=uuid4(), tenant_id=TENANT, name=f"g-{_sfx()}")
    db_session.add(grp)
    await db_session.flush()
    db_session.add(HostGroupMember(id=uuid4(), tenant_id=TENANT, host_group_id=grp.id, agent_id=agent.id))

    # same check assigned at three scopes with overlapping params
    await _assign(db_session, "mysql", "ou", ou=root, params={"port": 3306, "user": "root", "warn": 50})
    await _assign(db_session, "mysql", "group", group=grp, params={"user": "monitor", "warn": 70})
    await _assign(db_session, "mysql", "host", agent=agent, params={"warn": 90})
    await db_session.flush()

    eff = await resolve_host_checks(db_session, agent)
    assert len(eff) == 1
    ec = eff[0]
    assert ec.check_name == "mysql"
    assert ec.source_scope == "host"           # most specific wins as the "source"
    # GPO precedence is global < group < OU < host: params merged weakest→
    # strongest, so host sets warn=90, OU (stronger than group) sets user=root
    # and port=3306; the group's user=monitor/warn=70 are overridden.
    assert ec.parameters == {"port": 3306, "user": "root", "warn": 90}
    assert len(ec.contributing) == 3


async def test_ou_inheritance_reaches_descendant_host(db_session):
    root = await _ou(db_session, "Databases")
    child = await _ou(db_session, "Prod", parent=root)
    agent = await _agent(db_session, child)
    # assigned on the ROOT ou -> inherited by the host under the child ou
    await _assign(db_session, "disk", "ou", ou=root, params={"crit": 95})
    await db_session.flush()

    eff = await resolve_host_checks(db_session, agent)
    names = {e.check_name: e for e in eff}
    assert "disk" in names
    assert names["disk"].source_scope == "ou"
    assert names["disk"].parameters == {"crit": 95}


async def test_unrelated_scopes_do_not_apply(db_session):
    other_ou = await _ou(db_session, "Web")
    agent = await _agent(db_session, ou=None)  # unassigned host
    await _assign(db_session, "apache", "ou", ou=other_ou, params={})
    await db_session.flush()

    eff = await resolve_host_checks(db_session, agent)
    assert all(e.check_name != "apache" for e in eff)


async def test_disabled_assignment_ignored(db_session):
    agent = await _agent(db_session)
    a = await _assign(db_session, "ntp", "host", agent=agent, params={})
    a.enabled = False
    await db_session.flush()
    eff = await resolve_host_checks(db_session, agent)
    assert all(e.check_name != "ntp" for e in eff)
