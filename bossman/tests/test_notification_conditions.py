"""Notification rules honour the shared rule-conditions object.

"A rule gets a filter" was true for 5 of 11 rule kinds; NotificationRule was one of the six that
could not say "notify only for these host groups", even after the UI grew one control for it.

Two things are load-bearing here and both are tested rather than assumed:

  * an EMPTY condition still matches, so every rule written before the column existed behaves exactly
    as it did — this is the whole reason the migration needs no backfill;
  * the expensive MatchContext is built ONLY when some rule actually states a condition. Notification
    dispatch runs per event, so paying for labels + facts + scope vars unconditionally would tax every
    alert on a fleet that uses none. The gate mirrors the lazy trick _event_context already uses for
    policy scope.
"""

import uuid

import pytest

from bossman.db.models import Agent, HostGroup, HostGroupMember, NotificationRule
from bossman.services.notification import NotifyEvent, _conditions_gate
from tests.naming import owned_name

TENANT = uuid.UUID("00000000-0000-0000-0000-000000000001")


async def _agent(db_session, groups: list[str] | None = None) -> Agent:
    a = Agent(id=uuid.uuid4(), tenant_id=TENANT, name=owned_name("nhost"), token="t",
              mode="standalone", enrollment_state="enrolled")
    db_session.add(a)
    await db_session.flush()
    for name in groups or []:
        g = HostGroup(id=uuid.uuid4(), tenant_id=TENANT, name=owned_name(name))
        db_session.add(g)
        await db_session.flush()
        db_session.add(HostGroupMember(tenant_id=TENANT, host_group_id=g.id, agent_id=a.id))
        # The condition names the group by its REAL name, which owned_name() has suffixed — so the
        # test asserts against what the fleet actually holds rather than a name it wishes for.
        a.__dict__.setdefault("_probe_groups", []).append(g.name)
    await db_session.flush()
    return a


def _rule(conditions: dict | None = None) -> NotificationRule:
    return NotificationRule(
        id=uuid.uuid4(), name=owned_name("nrule"), channel="email", target="ops@example.com",
        conditions=conditions or {},
    )


def _ev(agent: Agent) -> NotifyEvent:
    return NotifyEvent(agent_name=agent.name, service_name="Disk /", state="CRIT",
                       event="problem", output="full", agent_tags={})


async def test_no_conditions_anywhere_costs_nothing_and_passes_everything(db_session):
    """The cheap path: not one rule states a condition, so nothing is resolved."""
    agent = await _agent(db_session)
    rules = [_rule(), _rule()]
    gate = await _conditions_gate(db_session, _ev(agent), rules)
    assert all(gate(r) for r in rules)


async def test_an_empty_condition_still_matches(db_session):
    """Even on the expensive path — one rule has conditions, another does not. The one without must
    keep firing, or adding the column would silently change existing behaviour."""
    agent = await _agent(db_session, ["webs"])
    group = agent.__dict__["_probe_groups"][0]
    plain, filtered = _rule(), _rule({"host_groups": [group]})
    gate = await _conditions_gate(db_session, _ev(agent), [plain, filtered])
    assert gate(plain) is True


async def test_a_group_condition_selects_and_excludes(db_session):
    member = await _agent(db_session, ["webs"])
    group = member.__dict__["_probe_groups"][0]
    outsider = await _agent(db_session)

    rule = _rule({"host_groups": [group]})
    assert (await _conditions_gate(db_session, _ev(member), [rule]))(rule) is True
    assert (await _conditions_gate(db_session, _ev(outsider), [rule]))(rule) is False


async def test_negation_means_in_none_of_them(db_session):
    member = await _agent(db_session, ["staging"])
    group = member.__dict__["_probe_groups"][0]
    outsider = await _agent(db_session)

    rule = _rule({"host_groups": {"$nor": [group]}})
    assert (await _conditions_gate(db_session, _ev(member), [rule]))(rule) is False
    assert (await _conditions_gate(db_session, _ev(outsider), [rule]))(rule) is True


async def test_an_unknown_host_refuses_a_conditional_rule_but_not_a_plain_one(db_session):
    """An event from a host with no Agent row cannot be judged. A condition that cannot be evaluated
    must not pass: a rule narrowed to a group would otherwise page everyone. A rule WITHOUT a
    condition still fires, because nothing about it was in doubt."""
    ev = NotifyEvent(agent_name="ghost-host-does-not-exist", service_name="Disk /", state="CRIT",
                     event="problem", output="", agent_tags={})
    plain, filtered = _rule(), _rule({"host_groups": ["webservers"]})
    gate = await _conditions_gate(db_session, ev, [plain, filtered])
    assert gate(plain) is True
    assert gate(filtered) is False


@pytest.mark.parametrize("cond", [
    {"host_name": [{"$regex": "^nhost"}]},
    {"host_groups": []},          # empty list = unset, not "impossible"
    {},
])
async def test_conditions_that_must_not_block(db_session, cond):
    agent = await _agent(db_session)
    rule = _rule(cond)
    assert (await _conditions_gate(db_session, _ev(agent), [rule]))(rule) is True
