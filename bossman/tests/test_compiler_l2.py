"""Service-layer tests for the L2 approval gate additions to
services/compiler.py: the status filter, is_yolo_mode, affected_agent_ids,
and preview_plan_link. Real DB via db_session, no commits (fixture
rollback cleans up) — see tests/conftest.py.
"""

from uuid import UUID, uuid4
from tests.naming import run_suffix

from bossman.db.models import (
    Agent,
    HostGroup,
    HostGroupMember,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OrchestrationPlanVersion,
    OUNode,
    SystemSettings,
)
from bossman.services.compiler import (
    affected_agent_ids,
    compile_host_desired_state,
    is_yolo_mode,
    preview_plan_link,
)

DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000001"
SYSTEM_SETTINGS_ID = "00000000-0000-0000-0000-0000000000f1"


def _sfx() -> str:
    return run_suffix()


async def _agent(db_session, ou=None):
    agent = Agent(id=uuid4(), name=f"host-{_sfx()}", token="t", tenant_id=DEFAULT_TENANT_ID, ou_id=(ou.id if ou else None))
    db_session.add(agent)
    await db_session.flush()
    return agent


async def _plan(db_session, generated_monitoring=None):
    plan = OrchestrationPlan(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=f"plan-{_sfx()}", display_name="Plan", plan_type="role", current_version=1)
    db_session.add(plan)
    db_session.add(OrchestrationPlanVersion(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan.id, version=1, generated_monitoring=generated_monitoring or {}))
    await db_session.flush()
    return plan


async def _link(db_session, plan, target_type, *, agent=None, ou=None, group=None, status="active"):
    link = OrchestrationPlanLink(
        id=uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan.id, target_type=target_type,
        agent_id=(agent.id if agent else None), ou_id=(ou.id if ou else None),
        host_group_id=(group.id if group else None), status=status,
    )
    db_session.add(link)
    await db_session.flush()
    return link


# ---------------------------------------------------------------------------
# status filter


async def test_pending_link_has_no_compiled_effect(db_session):
    agent = await _agent(db_session)
    plan = await _plan(db_session, {"checks": ["docker_daemon"], "thresholds": {}})
    await _link(db_session, plan, "host", agent=agent, status="pending_approval")

    result = await compile_host_desired_state(db_session, agent.id)
    assert result.state["orchestration"]["roles"] == []
    assert result.state["monitoring"]["checks"] == []


async def test_rejected_link_has_no_compiled_effect(db_session):
    agent = await _agent(db_session)
    plan = await _plan(db_session)
    await _link(db_session, plan, "host", agent=agent, status="rejected")

    result = await compile_host_desired_state(db_session, agent.id)
    assert result.state["orchestration"]["roles"] == []


async def test_active_link_still_applies(db_session):
    agent = await _agent(db_session)
    plan = await _plan(db_session)
    await _link(db_session, plan, "host", agent=agent, status="active")

    result = await compile_host_desired_state(db_session, agent.id)
    assert result.state["orchestration"]["roles"] == [plan.name]


async def test_approving_a_pending_link_activates_it_on_recompile(db_session):
    agent = await _agent(db_session)
    plan = await _plan(db_session)
    link = await _link(db_session, plan, "host", agent=agent, status="pending_approval")

    before = await compile_host_desired_state(db_session, agent.id)
    assert before.state["orchestration"]["roles"] == []

    link.status = "active"
    await db_session.flush()
    after = await compile_host_desired_state(db_session, agent.id)
    assert after.state["orchestration"]["roles"] == [plan.name]
    assert after.generation > before.generation


# ---------------------------------------------------------------------------
# is_yolo_mode


async def test_is_yolo_mode_reads_the_singleton_row(db_session):
    settings = await db_session.get(SystemSettings, UUID(SYSTEM_SETTINGS_ID))
    original = settings.yolo_mode
    try:
        settings.yolo_mode = True
        await db_session.flush()
        assert await is_yolo_mode(db_session) is True

        settings.yolo_mode = False
        await db_session.flush()
        assert await is_yolo_mode(db_session) is False
    finally:
        settings.yolo_mode = original
        await db_session.flush()


# ---------------------------------------------------------------------------
# affected_agent_ids


async def test_affected_agent_ids_host(db_session):
    agent = await _agent(db_session)
    assert await affected_agent_ids(db_session, "host", agent_id=agent.id) == [agent.id]


async def test_affected_agent_ids_group(db_session):
    agent = await _agent(db_session)
    group = HostGroup(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=f"g-{_sfx()}")
    db_session.add(group)
    await db_session.flush()
    db_session.add(HostGroupMember(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, host_group_id=group.id, agent_id=agent.id))
    await db_session.flush()

    assert await affected_agent_ids(db_session, "group", host_group_id=group.id) == [agent.id]


async def test_affected_agent_ids_ou_subtree(db_session):
    rpath = f"/r-{_sfx()}"
    root = OUNode(
        id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=f"r-{_sfx()}", path=rpath,
        ltree_path=rpath.strip("/").replace("/", "."),
    )
    db_session.add(root)
    await db_session.flush()
    child = OUNode(
        id=uuid4(), tenant_id=DEFAULT_TENANT_ID, parent_id=root.id, name="child", path=f"{root.path}/child",
        ltree_path=f"{root.path.strip('/').replace('/', '.')}.child",
    )
    db_session.add(child)
    await db_session.flush()
    agent = await _agent(db_session, ou=child)

    assert await affected_agent_ids(db_session, "ou", ou_id=root.id) == [agent.id]


async def test_affected_agent_ids_global_needs_tenant(db_session):
    agent = await _agent(db_session)
    ids = await affected_agent_ids(db_session, "global", tenant_id=UUID(DEFAULT_TENANT_ID))
    assert agent.id in ids
    assert await affected_agent_ids(db_session, "global") == []


# ---------------------------------------------------------------------------
# preview_plan_link — never persists


async def test_preview_plan_link_reports_diff_without_persisting(db_session):
    agent = await _agent(db_session)
    plan = await _plan(db_session, {"checks": ["docker_daemon"], "thresholds": {}})

    result = await preview_plan_link(db_session, UUID(DEFAULT_TENANT_ID), plan.id, "host", agent_id=agent.id)
    assert result["affected_host_count"] == 1
    assert result["sample_diff"]["host"] == agent.name
    assert result["sample_diff"]["checks_added"] == ["docker_daemon"]
    assert result["sample_diff"]["roles_added"] == [plan.name]

    # The real desired state is unaffected.
    real = await compile_host_desired_state(db_session, agent.id)
    assert real.state["orchestration"]["roles"] == []


async def test_preview_plan_link_no_affected_hosts(db_session):
    plan = await _plan(db_session)
    group = HostGroup(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, name=f"empty-{_sfx()}")
    db_session.add(group)
    await db_session.flush()

    result = await preview_plan_link(db_session, UUID(DEFAULT_TENANT_ID), plan.id, "group", host_group_id=group.id)
    assert result["affected_host_count"] == 0
    assert result["sample_diff"] is None


async def test_preview_plan_link_missing_plan_returns_none(db_session):
    assert await preview_plan_link(db_session, UUID(DEFAULT_TENANT_ID), uuid4(), "global") is None
