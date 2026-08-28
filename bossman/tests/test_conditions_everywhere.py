"""Every rule kind with a host scope narrows by the same conditions object.

"A rule gets a filter" was true for 5 of 11 kinds. The other six were not a design decision, just
places the shared object had not reached — so a compliance rule could not say "only these host
groups" while a threshold could, and an operator had no way to know which was which.

The batch kinds (compliance, scheduled jobs, business services) all resolve hosts through
affected_agent_ids and then iterate, so they share ONE helper — filter_agent_ids. Three copies of a
matcher is how two of them end up disagreeing about what host_groups means, which is the failure this
file is here to prevent.

ScopeVars is absent on purpose: resolve_scope_vars is called BY build_match_context to supply
host_vars, so a conditional variable set would recurse into itself. That cycle is a design decision,
not a missing column.
"""

import uuid

from bossman.db.models import Agent, HostGroup, HostGroupMember
from bossman.services.check_assignments import filter_agent_ids
from tests.naming import owned_name

TENANT = uuid.UUID("00000000-0000-0000-0000-000000000001")


async def _agent(db_session, group_name: str | None = None) -> tuple[Agent, str | None]:
    a = Agent(id=uuid.uuid4(), tenant_id=TENANT, name=owned_name("chost"), token="t",
              mode="standalone", enrollment_state="enrolled")
    db_session.add(a)
    await db_session.flush()
    real = None
    if group_name:
        g = HostGroup(id=uuid.uuid4(), tenant_id=TENANT, name=owned_name(group_name))
        db_session.add(g)
        await db_session.flush()
        db_session.add(HostGroupMember(tenant_id=TENANT, host_group_id=g.id, agent_id=a.id))
        await db_session.flush()
        real = g.name
    return a, real


async def test_no_condition_returns_the_list_untouched(db_session):
    """The common case, and it must also be the cheap one: no condition means no MatchContext is
    built at all. Asserted on behaviour (identity of the list contents) since the absence of queries
    is what the implementation guarantees."""
    a, _ = await _agent(db_session)
    b, _ = await _agent(db_session)
    ids = [a.id, b.id]
    assert await filter_agent_ids(db_session, ids, None) == ids
    assert await filter_agent_ids(db_session, ids, {}) == ids


async def test_a_group_condition_narrows_the_scope(db_session):
    member, group = await _agent(db_session, "webs")
    outsider, _ = await _agent(db_session)
    got = await filter_agent_ids(db_session, [member.id, outsider.id], {"host_groups": [group]})
    assert got == [member.id]


async def test_negation_excludes_members(db_session):
    member, group = await _agent(db_session, "staging")
    outsider, _ = await _agent(db_session)
    got = await filter_agent_ids(db_session, [member.id, outsider.id],
                                 {"host_groups": {"$nor": [group]}})
    assert got == [outsider.id]


async def test_a_host_that_no_longer_exists_contributes_nothing(db_session):
    """A scope can name a host that has since been deleted. It must drop out rather than raise or be
    silently treated as matching — a compliance run or a scheduled job would otherwise either crash or
    act on a ghost."""
    a, group = await _agent(db_session, "webs")
    got = await filter_agent_ids(db_session, [a.id, uuid.uuid4()], {"host_groups": [group]})
    assert got == [a.id]


async def test_order_is_preserved(db_session):
    """Callers iterate the result; a filter that reordered hosts would make a scheduled job's run
    order depend on whether a condition happened to be set."""
    a, group = await _agent(db_session, "webs")
    b, _ = await _agent(db_session, None)
    db_session.add(HostGroupMember(
        tenant_id=TENANT,
        host_group_id=(await _group_id(db_session, group)),
        agent_id=b.id,
    ))
    await db_session.flush()
    ids = [b.id, a.id]
    assert await filter_agent_ids(db_session, ids, {"host_groups": [group]}) == ids


async def _group_id(db_session, name: str):
    from sqlalchemy import select
    return await db_session.scalar(select(HostGroup.id).where(HostGroup.name == name))


async def test_every_scoped_rule_kind_has_the_column():
    """The claim "a rule gets a filter" must be checkable, not remembered. If a new rule kind with a
    host scope is added without conditions, this fails and names it.

    ScopeVars is the one documented exception (the resolve_scope_vars cycle) and is listed as such
    rather than quietly omitted — an exception nobody can see is indistinguishable from an oversight.
    """
    from bossman.db import models

    expected = [
        "CheckRule", "CheckAssignment", "ConfigPolicy", "ConfigPolicySet", "RemediationPolicy",
        "OrchestrationPlanLink", "NotificationRule", "ComplianceRule", "ScheduledJob",
        "BusinessService",
    ]
    missing = [n for n in expected if not hasattr(getattr(models, n), "conditions")]
    assert not missing, f"scoped rule kinds without a conditions column: {missing}"
    # And the exception, asserted so that giving ScopeVars conditions has to be a deliberate act that
    # updates this test and its reasoning.
    assert not hasattr(models.ScopeVars, "conditions"), (
        "ScopeVars gained conditions — resolve_scope_vars is called BY build_match_context, so this "
        "recurses. If the cycle has been cut, say how here."
    )
