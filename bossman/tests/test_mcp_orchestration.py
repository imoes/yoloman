"""Real, DB-backed tests for the Policy/Orchestration MCP tools (Block L2)
— same "call tools directly via FastMCP.call_tool" approach as
tests/test_mcp_server.py.
"""

import json
import uuid
from tests.naming import owned_name, run_suffix
from uuid import UUID

import pytest
from mcp.server.fastmcp.exceptions import ToolError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from bossman.config import Settings, get_settings
from bossman.db.models import (
    Agent,
    HostGroup,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OrchestrationPlanVersion,
    OUNode,
    SystemSettings,
)
from bossman.mcp.auth import current_identity
from bossman.mcp.server import build_mcp_server
from bossman.services.catalog import CatalogCache

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")
SYSTEM_SETTINGS_ID = UUID("00000000-0000-0000-0000-0000000000f1")


class FakeAgentClient:
    async def call_tool(self, name, body):
        return {"changed": True}

    async def upload_file(self, remote_name, data):
        return {"path": f"/staged/{remote_name}", "bytes_written": len(data)}


class FakeEmbeddingClient:
    model = "fake-model"

    async def embed(self, texts):
        return [[0.0] * 1024 for _ in texts]


@pytest.fixture
async def session_factory(db_session):
    engine = create_async_engine(get_settings().database_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


def _settings(plans_dir: str) -> Settings:
    return Settings(database_url="postgresql+asyncpg://unused/unused", client_cert_path="/unused", client_key_path="/unused", plans_dir=plans_dir)


async def _call(mcp, name, args=None):
    result = await mcp.call_tool(name, args or {})
    if isinstance(result, tuple):
        _, structured = result
        if isinstance(structured, dict) and set(structured.keys()) == {"result"}:
            return structured["result"]
        return structured
    return json.loads(result[0].text)


def _mcp(session_factory, tmp_path):
    return build_mcp_server(session_factory, _settings(str(tmp_path)), CatalogCache(str(tmp_path)), FakeEmbeddingClient(), client_factory=lambda a, s: FakeAgentClient())


async def _make_agent(db_session, **overrides) -> Agent:
    fields = {"name": owned_name("mcp-orch"), "token": "tok", "mode": "standalone", "enrollment_state": "enrolled"}
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _make_plan(db_session, **generated_monitoring) -> OrchestrationPlan:
    plan = OrchestrationPlan(id=uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, name=owned_name("plan"), display_name="Plan", plan_type="role", current_version=1)
    db_session.add(plan)
    db_session.add(OrchestrationPlanVersion(id=uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan.id, version=1, generated_monitoring=generated_monitoring or {}))
    await db_session.flush()
    await db_session.commit()
    return plan


async def _cleanup_plan(db_session, plan):
    got = await db_session.get(OrchestrationPlan, plan.id)
    if got is not None:
        await db_session.delete(got)  # cascades versions + links
    await db_session.commit()


async def _cleanup_agent(db_session, agent):
    got = await db_session.get(Agent, agent.id)
    if got is not None:
        await db_session.delete(got)
    await db_session.commit()


async def _set_yolo_mode(db_session, enabled: bool):
    settings = await db_session.get(SystemSettings, SYSTEM_SETTINGS_ID)
    settings.yolo_mode = enabled
    await db_session.commit()


# ---------------------------------------------------------------------------
# Read-only tools


async def test_list_and_get_orchestration_plan(db_session, session_factory, tmp_path):
    plan = await _make_plan(db_session, checks=["docker_daemon"], thresholds={})
    mcp = _mcp(session_factory, tmp_path)

    listed = await _call(mcp, "list_orchestration_plans")
    assert any(p["name"] == plan.name for p in listed)

    detail = await _call(mcp, "get_orchestration_plan", {"plan": plan.name})
    assert detail["generated_monitoring"]["checks"] == ["docker_daemon"]

    with pytest.raises(ToolError, match="no such orchestration plan"):
        await _call(mcp, "get_orchestration_plan", {"plan": "does-not-exist"})

    await _cleanup_plan(db_session, plan)


async def test_list_host_groups(db_session, session_factory, tmp_path):
    group = HostGroup(id=uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, name=owned_name("grp"))
    db_session.add(group)
    await db_session.commit()
    mcp = _mcp(session_factory, tmp_path)

    listed = await _call(mcp, "list_host_groups")
    assert any(g["name"] == group.name and g["member_count"] == 0 for g in listed)

    await db_session.delete(group)
    await db_session.commit()


async def test_get_ou_tree(db_session, session_factory, tmp_path):
    sfx = run_suffix()
    root = OUNode(id=uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, name=f"Root-{sfx}", path=f"/Root-{sfx}", ltree_path=f"Root_{sfx}")
    db_session.add(root)
    await db_session.commit()
    mcp = _mcp(session_factory, tmp_path)

    tree = await _call(mcp, "get_ou_tree")
    assert any(n["path"] == f"/Root-{sfx}" for n in tree)

    await db_session.delete(root)
    await db_session.commit()


async def test_get_host_desired_state(db_session, session_factory, tmp_path):
    agent = await _make_agent(db_session)
    plan = await _make_plan(db_session, checks=["docker_daemon"], thresholds={})
    link = OrchestrationPlanLink(id=uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan.id, target_type="host", agent_id=agent.id, status="active")
    db_session.add(link)
    await db_session.commit()

    mcp = _mcp(session_factory, tmp_path)
    result = await _call(mcp, "get_host_desired_state", {"host": agent.name})
    assert plan.name in result["state"]["orchestration"]["roles"]
    assert "docker_daemon" in result["state"]["monitoring"]["checks"]

    with pytest.raises(ToolError, match="no such host"):
        await _call(mcp, "get_host_desired_state", {"host": "nope"})

    await _cleanup_agent(db_session, agent)
    await _cleanup_plan(db_session, plan)


# ---------------------------------------------------------------------------
# Dry-run preview — never persists


async def test_preview_orchestration_plan_link_writes_nothing(db_session, session_factory, tmp_path):
    agent = await _make_agent(db_session)
    plan = await _make_plan(db_session, checks=["docker_daemon"], thresholds={})
    mcp = _mcp(session_factory, tmp_path)

    preview = await _call(mcp, "preview_orchestration_plan_link", {"plan": plan.name, "target_type": "host", "target": agent.name})
    assert preview["affected_host_count"] == 1
    assert preview["sample_diff"]["checks_added"] == ["docker_daemon"]

    links = (await db_session.scalars(select(OrchestrationPlanLink).where(OrchestrationPlanLink.plan_id == plan.id))).all()
    assert links == []  # nothing persisted

    await _cleanup_agent(db_session, agent)
    await _cleanup_plan(db_session, plan)


# ---------------------------------------------------------------------------
# The gated write tool


async def test_propose_orchestration_plan_link_starts_pending_approval(db_session, session_factory, tmp_path):
    agent = await _make_agent(db_session)
    plan = await _make_plan(db_session, checks=["docker_daemon"], thresholds={})
    mcp = _mcp(session_factory, tmp_path)

    reset = current_identity.set("mcp-orch-tester")
    try:
        result = await _call(mcp, "propose_orchestration_plan_link", {"plan": plan.name, "target_type": "host", "target": agent.name})
    finally:
        current_identity.reset(reset)

    assert result["status"] == "pending_approval"

    link = await db_session.get(OrchestrationPlanLink, UUID(result["link_id"]))
    assert link.status == "pending_approval"
    assert link.auto_apply is False
    assert link.require_approval is True
    assert link.created_by == "mcp-orch-tester"

    # A pending link has zero effect on the host's desired state.
    state = await _call(mcp, "get_host_desired_state", {"host": agent.name})
    assert state["state"]["orchestration"]["roles"] == []

    pending = await _call(mcp, "list_pending_orchestration_links")
    assert any(p["link_id"] == result["link_id"] for p in pending)

    await db_session.delete(link)
    await db_session.commit()
    await _cleanup_agent(db_session, agent)
    await _cleanup_plan(db_session, plan)


async def test_propose_orchestration_plan_link_active_when_yolo_mode_on(db_session, session_factory, tmp_path):
    agent = await _make_agent(db_session)
    plan = await _make_plan(db_session, checks=["docker_daemon"], thresholds={})
    mcp = _mcp(session_factory, tmp_path)

    await _set_yolo_mode(db_session, True)
    try:
        result = await _call(mcp, "propose_orchestration_plan_link", {"plan": plan.name, "target_type": "host", "target": agent.name})
        assert result["status"] == "active"

        state = await _call(mcp, "get_host_desired_state", {"host": agent.name})
        assert plan.name in state["state"]["orchestration"]["roles"]
    finally:
        await _set_yolo_mode(db_session, False)

    link = await db_session.get(OrchestrationPlanLink, UUID(result["link_id"]))
    await db_session.delete(link)
    await db_session.commit()
    await _cleanup_agent(db_session, agent)
    await _cleanup_plan(db_session, plan)


async def test_propose_orchestration_plan_link_unknown_target_raises(db_session, session_factory, tmp_path):
    plan = await _make_plan(db_session)
    mcp = _mcp(session_factory, tmp_path)

    with pytest.raises(ToolError, match="no such host"):
        await _call(mcp, "propose_orchestration_plan_link", {"plan": plan.name, "target_type": "host", "target": "nope"})

    await _cleanup_plan(db_session, plan)
