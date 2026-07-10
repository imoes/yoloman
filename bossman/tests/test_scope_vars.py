"""Block G11 — GPO variable resolution (group < OU root→leaf < host)."""

from uuid import uuid4

from bossman.db.models import Agent, HostGroup, HostGroupMember, OUNode, ScopeVars
from bossman.services.scope_vars import resolve_scope_vars

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
    a = Agent(id=uuid4(), name=f"sv-{_sfx()}", token="t", tenant_id=TENANT, ou_id=(ou.id if ou else None))
    db_session.add(a)
    await db_session.flush()
    return a


async def _vars(db_session, scope_type, vars, *, ou=None, group=None, agent=None):
    db_session.add(ScopeVars(id=uuid4(), tenant_id=TENANT, scope_type=scope_type,
                             ou_id=(ou.id if ou else None), host_group_id=(group.id if group else None),
                             agent_id=(agent.id if agent else None), vars=vars))
    await db_session.flush()


async def test_precedence_group_ou_host(db_session):
    root = await _ou(db_session, "DB")
    child = await _ou(db_session, "Prod", parent=root)
    agent = await _agent(db_session, child)
    grp = HostGroup(id=uuid4(), tenant_id=TENANT, name=f"g-{_sfx()}")
    db_session.add(grp)
    await db_session.flush()
    db_session.add(HostGroupMember(id=uuid4(), tenant_id=TENANT, host_group_id=grp.id, agent_id=agent.id))

    await _vars(db_session, "group", {"port": 1, "user": "grp", "region": "eu"}, group=grp)
    await _vars(db_session, "ou", {"user": "ou", "region": "eu-root"}, ou=root)       # stronger than group
    await _vars(db_session, "ou", {"region": "eu-prod"}, ou=child)                    # deeper OU stronger
    await _vars(db_session, "host", {"user": "host"}, agent=agent)                    # strongest
    await db_session.flush()

    merged = await resolve_scope_vars(db_session, agent)
    assert merged == {"port": 1, "user": "host", "region": "eu-prod"}


async def test_only_reaching_scopes(db_session):
    other_ou = await _ou(db_session, "Web")
    agent = await _agent(db_session, ou=None)
    await _vars(db_session, "ou", {"x": "1"}, ou=other_ou)     # unrelated OU
    await db_session.flush()
    assert await resolve_scope_vars(db_session, agent) == {}
