"""Service-layer tests for the Policy/Orchestration compiler (Block L1) —
real DB via the db_session fixture, no commits, so the fixture's rollback
wipes every row the test created (compiler functions only flush, never
commit). See tests/conftest.py.
"""

from uuid import uuid4
from tests.naming import run_suffix

from sqlalchemy import select

from bossman.db.models import (
    Agent,
    CheckRule,
    CompiledHostState,
    HostGroup,
    HostGroupMember,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OrchestrationPlanVersion,
    OUNode,
)
from bossman.services.compiler import (
    compile_host_desired_state,
    derive_generated_monitoring,
    resolve_host_group_ids,
    resolve_host_thresholds,
    resolve_ou_ancestry,
)

DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000001"


def _sfx() -> str:
    return run_suffix()


async def _ou(db_session, name, parent=None):
    sfx = _sfx()
    path = (parent.path if parent is not None else "") + "/" + f"{name}-{sfx}"
    node = OUNode(
        id=uuid4(), tenant_id=DEFAULT_TENANT_ID, parent_id=(parent.id if parent else None),
        name=f"{name}-{sfx}", path=path, ltree_path=path.strip("/").replace("/", "."),
    )
    db_session.add(node)
    await db_session.flush()
    return node


async def _agent(db_session, ou=None):
    agent = Agent(
        id=uuid4(), name=f"host-{_sfx()}", token="t", tenant_id=DEFAULT_TENANT_ID,
        ou_id=(ou.id if ou else None),
    )
    db_session.add(agent)
    await db_session.flush()
    return agent


async def _plan(db_session, plan_type="role", version=1, generated_monitoring=None, default_parameters=None):
    plan = OrchestrationPlan(
        id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=f"plan-{_sfx()}", display_name="Plan",
        plan_type=plan_type, current_version=version,
    )
    db_session.add(plan)
    db_session.add(
        OrchestrationPlanVersion(
            id=uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan.id, version=version,
            default_parameters=default_parameters or {},
            generated_monitoring=generated_monitoring or {},
        )
    )
    await db_session.flush()
    return plan


async def _link(
    db_session, plan, target_type, *, ou=None, agent=None, group=None, parameters=None, priority=100,
    link_order=100, status="active",
):
    # status="active" by default: these tests exercise assignment-resolution
    # mechanics, not the L2 approval gate (see test_compiler_l2.py) — the
    # model's own default is "pending_approval", which resolve_orchestration_assignments
    # deliberately ignores.
    link = OrchestrationPlanLink(
        id=uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan.id, target_type=target_type,
        ou_id=(ou.id if ou else None), agent_id=(agent.id if agent else None),
        host_group_id=(group.id if group else None), parameters=parameters or {},
        priority=priority, link_order=link_order, status=status,
    )
    db_session.add(link)
    await db_session.flush()
    return link


# ---------------------------------------------------------------------------
# OU ancestry + group membership


async def test_ou_ancestry_root_first(db_session):
    root = await _ou(db_session, "Germany")
    mid = await _ou(db_session, "Munich", parent=root)
    leaf = await _ou(db_session, "Prod", parent=mid)

    chain = await resolve_ou_ancestry(db_session, leaf.id)
    assert [n.id for n in chain] == [root.id, mid.id, leaf.id]


async def test_ou_ancestry_cycle_safe(db_session):
    a = await _ou(db_session, "A")
    b = await _ou(db_session, "B", parent=a)
    # Force a cycle a<->b (only possible by mutating parent_id directly).
    a.parent_id = b.id
    await db_session.flush()

    chain = await resolve_ou_ancestry(db_session, b.id)
    # Terminates; each node visited at most once.
    assert len({n.id for n in chain}) == len(chain)


async def test_ou_ancestry_none(db_session):
    assert await resolve_ou_ancestry(db_session, None) == []


async def test_host_group_membership(db_session):
    agent = await _agent(db_session)
    g1 = HostGroup(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=f"g1-{_sfx()}")
    g2 = HostGroup(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=f"g2-{_sfx()}")
    db_session.add_all([g1, g2])
    await db_session.flush()
    db_session.add_all([
        HostGroupMember(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, host_group_id=g1.id, agent_id=agent.id),
        HostGroupMember(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, host_group_id=g2.id, agent_id=agent.id),
    ])
    await db_session.flush()

    assert await resolve_host_group_ids(db_session, agent.id) == {g1.id, g2.id}


# ---------------------------------------------------------------------------
# Inheritance: OU / group / host-direct links reach the host


async def test_compile_inherits_ou_link(db_session):
    root = await _ou(db_session, "Germany")
    leaf = await _ou(db_session, "Prod", parent=root)
    agent = await _agent(db_session, ou=leaf)
    plan = await _plan(db_session, generated_monitoring={"checks": ["docker_daemon"], "thresholds": {}})
    # Link on the ANCESTOR ou — must reach the host in the subtree.
    await _link(db_session, plan, "ou", ou=root)

    result = await compile_host_desired_state(db_session, agent.id)
    assert result is not None and result.changed
    assert result.state["orchestration"]["roles"] == [plan.name]
    assert "docker_daemon" in result.state["monitoring"]["checks"]
    assert result.state["host"]["ou"] == leaf.path


async def test_compile_group_link(db_session):
    agent = await _agent(db_session)
    group = HostGroup(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=f"grp-{_sfx()}")
    db_session.add(group)
    await db_session.flush()
    db_session.add(HostGroupMember(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, host_group_id=group.id, agent_id=agent.id))
    await db_session.flush()
    plan = await _plan(db_session)
    await _link(db_session, plan, "group", group=group)

    result = await compile_host_desired_state(db_session, agent.id)
    assert result is not None
    assert plan.name in result.state["orchestration"]["roles"]


async def test_compile_host_direct_link(db_session):
    agent = await _agent(db_session)
    plan = await _plan(db_session)
    await _link(db_session, plan, "host", agent=agent)

    result = await compile_host_desired_state(db_session, agent.id)
    assert plan.name in result.state["orchestration"]["roles"]


async def test_compile_global_link(db_session):
    agent = await _agent(db_session)
    plan = await _plan(db_session)
    await _link(db_session, plan, "global")

    result = await compile_host_desired_state(db_session, agent.id)
    assert plan.name in result.state["orchestration"]["roles"]


# ---------------------------------------------------------------------------
# Precedence + parameter merge


async def test_link_precedence_host_over_ou(db_session):
    root = await _ou(db_session, "Germany")
    agent = await _agent(db_session, ou=root)
    plan = await _plan(db_session, default_parameters={"docker_version": "stable"})
    # Same plan linked twice: OU sets one value, host-direct another. Host wins.
    await _link(db_session, plan, "ou", ou=root, parameters={"docker_version": "ou-value"})
    await _link(db_session, plan, "host", agent=agent, parameters={"docker_version": "host-value"})

    result = await compile_host_desired_state(db_session, agent.id)
    plans = result.state["orchestration"]["plans"]
    assert len(plans) == 1  # deduplicated to one assignment
    assert plans[0]["parameters"]["docker_version"] == "host-value"


async def test_parameters_merge_over_version_defaults(db_session):
    agent = await _agent(db_session)
    plan = await _plan(db_session, default_parameters={"a": "1", "b": "2"})
    await _link(db_session, plan, "host", agent=agent, parameters={"b": "override", "c": "3"})

    result = await compile_host_desired_state(db_session, agent.id)
    params = result.state["orchestration"]["plans"][0]["parameters"]
    assert params == {"a": "1", "b": "override", "c": "3"}


# ---------------------------------------------------------------------------
# generated_monitoring union


async def test_generated_monitoring_union(db_session):
    agent = await _agent(db_session)
    p1 = await _plan(db_session, generated_monitoring={"checks": ["docker_daemon"], "thresholds": {"disk.pct": {"warning": 80}}})
    p2 = await _plan(db_session, generated_monitoring={"checks": ["postgres_health"], "thresholds": {"lag.s": {"critical": 300}}})
    await _link(db_session, p1, "host", agent=agent)
    await _link(db_session, p2, "host", agent=agent)

    result = await compile_host_desired_state(db_session, agent.id)
    mon = result.state["monitoring"]
    assert set(mon["checks"]) == {"docker_daemon", "postgres_health"}
    # Subset, not equality: globally-scoped default check_rules (Memory / Disk / Disk IOPS
    # are seeded) also contribute thresholds to every host, and this test is about the UNION
    # of the two plans' own thresholds, not about being the only source.
    assert mon["thresholds"]["disk.pct"] == {"warning": 80}
    assert mon["thresholds"]["lag.s"] == {"critical": 300}


def test_derive_generated_monitoring_dedups():
    from bossman.services.compiler import ResolvedAssignment

    a = ResolvedAssignment(uuid4(), "p1", "role", 1, {}, "host", {"checks": ["x", "y"], "thresholds": {}})
    b = ResolvedAssignment(uuid4(), "p2", "role", 1, {}, "host", {"checks": ["y", "z"], "thresholds": {}})
    out = derive_generated_monitoring([a, b])
    assert out["checks"] == ["x", "y", "z"]


# ---------------------------------------------------------------------------
# generation + hash


async def test_hash_stable_no_new_generation(db_session):
    agent = await _agent(db_session)
    plan = await _plan(db_session)
    await _link(db_session, plan, "host", agent=agent)

    first = await compile_host_desired_state(db_session, agent.id)
    assert first.changed and first.generation == 1
    second = await compile_host_desired_state(db_session, agent.id)
    assert not second.changed
    assert second.generation == 1
    assert second.config_hash == first.config_hash

    # Exactly one is_current row.
    rows = (await db_session.scalars(
        select(CompiledHostState).where(CompiledHostState.agent_id == agent.id)
    )).all()
    assert len(rows) == 1
    assert rows[0].is_current


async def test_generation_bump_on_change(db_session):
    agent = await _agent(db_session)
    plan = await _plan(db_session)
    link = await _link(db_session, plan, "host", agent=agent, parameters={"v": "1"})

    first = await compile_host_desired_state(db_session, agent.id)
    assert first.generation == 1

    # Change the link's parameters → new desired state → new generation.
    link.parameters = {"v": "2"}
    await db_session.flush()
    second = await compile_host_desired_state(db_session, agent.id)
    assert second.changed
    assert second.generation == 2
    assert second.config_hash != first.config_hash

    rows = (await db_session.scalars(
        select(CompiledHostState).where(CompiledHostState.agent_id == agent.id).order_by(CompiledHostState.generation)
    )).all()
    assert [r.generation for r in rows] == [1, 2]
    assert [r.is_current for r in rows] == [False, True]


async def test_compile_missing_agent_returns_none(db_session):
    assert await compile_host_desired_state(db_session, uuid4()) is None


async def test_policy_inline_roles_reach_orchestration_roles(db_session):
    # Block L3f: a Policy (plan) can declare multiple roles inline via
    # generated_monitoring.roles; they must surface in the compiled
    # orchestration.roles even though the plan's own type isn't 'role'.
    agent = await _agent(db_session)
    plan = await _plan(
        db_session, plan_type="deployment",
        generated_monitoring={"checks": [], "thresholds": {}, "roles": ["docker_host", "web_server"]},
    )
    await _link(db_session, plan, "host", agent=agent)

    result = await compile_host_desired_state(db_session, agent.id)
    roles = result.state["orchestration"]["roles"]
    assert "docker_host" in roles and "web_server" in roles


# ---------------------------------------------------------------------------
# Block L4-behavioral: GPO-resolved check_rule thresholds folded into the
# compiled desired state's monitoring.thresholds.


async def _check_rule(db_session, metric, *, scope_type, warn, crit, ou=None, scope_value=None,
                      comparison="gt", enforced=False, link_order=100):
    # NB: check_rules predate the multi-tenant L1 layer and carry no
    # tenant_id — applicability is entirely via scope (global/group/host/ou).
    rule = CheckRule(
        id=uuid4(), service_name=f"{metric} check", metric=metric,
        comparison=comparison, warn_threshold=warn, crit_threshold=crit, scope_type=scope_type,
        scope_value=scope_value, scope_ou_id=(ou.id if ou else None), enforced=enforced,
        link_order=link_order, enabled=True,
    )
    db_session.add(rule)
    await db_session.flush()
    return rule


async def test_thresholds_ou_rule_reaches_host(db_session):
    ou = await _ou(db_session, "Prod")
    agent = await _agent(db_session, ou=ou)
    await _check_rule(db_session, "mem_used_pct", scope_type="ou", ou=ou, warn=70.0, crit=85.0)

    result = await compile_host_desired_state(db_session, agent.id)
    th = result.state["monitoring"]["thresholds"]["mem_used_pct"]
    assert th["warn"] == 70.0 and th["crit"] == 85.0 and th["comparison"] == "gt"


async def test_thresholds_host_rule_overrides_ou(db_session):
    ou = await _ou(db_session, "Prod")
    agent = await _agent(db_session, ou=ou)
    # A shallower OU rule and a host-direct rule for the same metric — the
    # closest level (host) must win, exactly like GPO precedence.
    await _check_rule(db_session, "load5", scope_type="ou", ou=ou, warn=1.0, crit=2.0)
    await _check_rule(db_session, "load5", scope_type="host", scope_value=agent.name, warn=4.0, crit=8.0)

    thresholds = await resolve_host_thresholds(db_session, agent, await resolve_ou_ancestry(db_session, agent.ou_id))
    assert thresholds["load5"]["warn"] == 4.0 and thresholds["load5"]["crit"] == 8.0


async def test_thresholds_enforced_higher_level_wins(db_session):
    parent = await _ou(db_session, "Germany")
    child = await _ou(db_session, "Munich", parent=parent)
    agent = await _agent(db_session, ou=child)
    # An ENFORCED rule at the shallower OU beats a normal rule at the closer
    # OU (enforced can't be overridden from below) — GPO semantics.
    await _check_rule(db_session, "disk_used_pct", scope_type="ou", ou=parent, warn=60.0, crit=75.0, enforced=True)
    await _check_rule(db_session, "disk_used_pct", scope_type="ou", ou=child, warn=90.0, crit=95.0)

    result = await compile_host_desired_state(db_session, agent.id)
    th = result.state["monitoring"]["thresholds"]["disk_used_pct"]
    assert th["warn"] == 60.0 and th["crit"] == 75.0


async def test_thresholds_check_rule_wins_over_plan(db_session):
    ou = await _ou(db_session, "Prod")
    agent = await _agent(db_session, ou=ou)
    # A plan contributes a mem_used_pct default; a console check_rule for the
    # same metric must win (deliberate host config over role default).
    plan = await _plan(db_session, generated_monitoring={"checks": ["mem"], "thresholds": {"mem_used_pct": {"warn": 50}}})
    await _link(db_session, plan, "ou", ou=ou)
    await _check_rule(db_session, "mem_used_pct", scope_type="ou", ou=ou, warn=88.0, crit=94.0)

    result = await compile_host_desired_state(db_session, agent.id)
    th = result.state["monitoring"]["thresholds"]["mem_used_pct"]
    assert th["warn"] == 88.0 and th["crit"] == 94.0


async def test_thresholds_come_only_from_real_rules(db_session):
    """A host with no plan of its own gets exactly the thresholds its rules imply.

    This asserted an EMPTY map, on the premise "no check_rules". That premise stopped being
    true: globally-scoped default rules are seeded and apply to every host by definition. (It
    passed for a while only because an older, destructive seeding test had deleted those
    defaults from the shared database — so the test depended on the system being broken.) What
    is still worth pinning is that nothing appears out of thin air and the compile does not
    crash.
    """
    from sqlalchemy import select as _select

    from bossman.db.models import CheckRule

    agent = await _agent(db_session)
    result = await compile_host_desired_state(db_session, agent.id)
    thresholds = result.state["monitoring"]["thresholds"]

    metrics_with_rules = {
        r.metric
        for r in (
            await db_session.scalars(
                _select(CheckRule).where(CheckRule.enabled == True, CheckRule.scope_type == "global")  # noqa: E712
            )
        ).all()
    }
    assert set(thresholds) <= metrics_with_rules, "a threshold with no rule behind it"
