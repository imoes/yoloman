"""Real, DB-backed tests for bossman.mcp.server — see
tests/conftest.py's db_session fixture. Calls tools directly via
FastMCP.call_tool rather than driving a full MCP JSON-RPC session, the
same "test the closures directly" approach the poller/plan-engine tests
already use for their own service functions. A FakeAgentClient (no real
network) is injected via build_mcp_server's client_factory parameter.
"""

import json
import uuid
from datetime import datetime, timezone

import pytest
from mcp.server.fastmcp.exceptions import ToolError
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from bossman.config import Settings, get_settings
from bossman.db.models import Agent, HostEdge, Metric, PlanEmbedding, PlanRun
from bossman.mcp.auth import current_identity
from bossman.mcp.server import build_mcp_server
from bossman.services.catalog import CatalogCache


class FakeAgentClient:
    def __init__(self):
        self.tool_calls = []

    async def call_tool(self, name, body):
        self.tool_calls.append((name, body))
        return {"changed": True}

    async def upload_file(self, remote_name, data):
        return {"path": f"/staged/{remote_name}", "bytes_written": len(data)}


class FakeEmbeddingClient:
    """A minimal fake satisfying EmbeddingClient's interface for tests that
    don't exercise search_plans — build_mcp_server now always needs one,
    but most tests here never call the tool that would actually use it."""

    model = "fake-model"

    def __init__(self, vectors: dict[str, list[float]] | None = None):
        self._vectors = vectors or {}

    async def embed(self, texts: list[str]) -> list[list[float]]:
        return [self._vectors.get(t, [0.0] * 1024) for t in texts]


@pytest.fixture
async def session_factory(db_session):  # depends on db_session purely for its reachability skip-check
    engine = create_async_engine(get_settings().database_url)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    yield factory
    await engine.dispose()


def _settings(plans_dir: str, **overrides) -> Settings:
    kwargs = {
        "database_url": "postgresql+asyncpg://unused/unused",
        "client_cert_path": "/unused",
        "client_key_path": "/unused",
        "plans_dir": plans_dir,
    }
    kwargs.update(overrides)
    return Settings(**kwargs)


async def _call(mcp, name, args=None):
    """Calls an MCP tool and returns its actual Python value. FastMCP's
    call_tool return shape depends on the tool's declared return type: a
    dict-returning tool comes back as a bare list of ContentBlocks (one
    TextContent holding the whole JSON object); a list-returning tool
    comes back as (content_blocks, {"result": [...]}) instead — the
    content blocks are one-per-list-item there, not the whole array, so
    the structured second element is what actually holds the full list."""
    result = await mcp.call_tool(name, args or {})
    if isinstance(result, tuple):
        _, structured = result
        if isinstance(structured, dict) and set(structured.keys()) == {"result"}:
            return structured["result"]
        return structured
    return json.loads(result[0].text)


async def _make_agent(db_session, **overrides) -> Agent:
    fields = {
        "name": f"mcp-agent-{uuid.uuid4().hex[:8]}",
        "token": "tok",
        "address": "10.0.0.7:8010",
        "mode": "standalone",
        "enrollment_state": "enrolled",
    }
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


MODULE_PLAN = """
name: mcp_demo_plan
description: "MCP facade test plan"
params:
  message: { type: string, required: true }
steps:
  - name: write_it
    ansible.builtin.copy:
      dest: /etc/motd
      content: "{{ message }}"
"""


async def test_list_hosts_returns_real_agents(db_session, session_factory, tmp_path):
    agent = await _make_agent(db_session)
    settings = _settings(str(tmp_path))
    fake = FakeAgentClient()
    mcp = build_mcp_server(session_factory, settings, CatalogCache(str(tmp_path)), FakeEmbeddingClient(), client_factory=lambda a, s: fake)

    hosts = await _call(mcp, "list_hosts")

    assert any(h["name"] == agent.name for h in hosts)

    await db_session.delete(agent)
    await db_session.commit()


async def test_host_status_includes_metrics_and_last_run(db_session, session_factory, tmp_path):
    agent = await _make_agent(db_session)
    metric = Metric(time=datetime.now(timezone.utc), agent_id=agent.id, metric="cpu_pct", value=3.5, labels={})
    run = PlanRun(plan_name="demo", agent_id=agent.id, params={}, dry_run=False, status="succeeded")
    db_session.add_all([metric, run])
    await db_session.flush()
    await db_session.commit()

    settings = _settings(str(tmp_path))
    mcp = build_mcp_server(session_factory, settings, CatalogCache(str(tmp_path)), FakeEmbeddingClient(), client_factory=lambda a, s: FakeAgentClient())

    status = await _call(mcp, "host_status", {"host": agent.name})

    assert status["name"] == agent.name
    assert any(m["metric"] == "cpu_pct" for m in status["recent_metrics"])
    assert status["last_plan_run"]["plan_name"] == "demo"

    await db_session.delete(run)
    await db_session.delete(metric)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def test_host_status_unknown_host_raises(db_session, session_factory, tmp_path):
    settings = _settings(str(tmp_path))
    mcp = build_mcp_server(session_factory, settings, CatalogCache(str(tmp_path)), FakeEmbeddingClient(), client_factory=lambda a, s: FakeAgentClient())

    with pytest.raises(ToolError, match="no such host"):
        await mcp.call_tool("host_status", {"host": "does-not-exist"})


async def test_host_relationships_returns_edges(db_session, session_factory, tmp_path):
    agent = await _make_agent(db_session)
    now = datetime.now(timezone.utc)
    edge = HostEdge(
        src_agent_id=agent.id, src_comm="curl", dst_addr="9.9.9.9", dst_port=443,
        event_count=2, first_seen_at=now, last_seen_at=now, latency_ms_p50=2.5,
    )
    db_session.add(edge)
    await db_session.flush()
    await db_session.commit()

    settings = _settings(str(tmp_path))
    mcp = build_mcp_server(session_factory, settings, CatalogCache(str(tmp_path)), FakeEmbeddingClient(), client_factory=lambda a, s: FakeAgentClient())

    result = await _call(mcp, "host_relationships", {"host": agent.name})

    assert len(result["edges"]) == 1
    assert result["edges"][0]["dst_addr"] == "9.9.9.9"
    assert result["edges"][0]["latency_ms_p50"] == 2.5

    await db_session.delete(edge)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def test_list_plans_and_get_catalog(db_session, session_factory, tmp_path):
    (tmp_path / "mcp_demo_plan.yaml").write_text(MODULE_PLAN)
    settings = _settings(str(tmp_path))
    cache = CatalogCache(str(tmp_path))
    mcp = build_mcp_server(session_factory, settings, cache, FakeEmbeddingClient(), client_factory=lambda a, s: FakeAgentClient())

    plans = await _call(mcp, "list_plans")
    assert plans[0]["name"] == "mcp_demo_plan"
    assert plans[0]["params"]["message"]["required"] is True

    catalog_result = await mcp.call_tool("get_catalog", {})
    content = catalog_result[0] if isinstance(catalog_result, tuple) else catalog_result
    assert "mcp_demo_plan" in content[0].text
    assert content[0].text == cache.catalog_markdown  # byte-identical to the cache, not re-rendered


def _vec(*components: float, dim: int = 1024) -> list[float]:
    padded = list(components) + [0.0] * (dim - len(components))
    return padded[:dim]


async def test_search_plans_finds_relevant_plan(db_session, session_factory, tmp_path):
    (tmp_path / "mcp_demo_plan.yaml").write_text(MODULE_PLAN)
    settings = _settings(str(tmp_path), plan_search_threshold=0.75)
    cache = CatalogCache(str(tmp_path))
    embedding_client = FakeEmbeddingClient(
        {
            "mcp_demo_plan: MCP facade test plan": _vec(1.0, 0.0),
            "a plan for the mcp facade": _vec(0.99, 0.01),
        }
    )
    mcp = build_mcp_server(session_factory, settings, cache, embedding_client, client_factory=lambda a, s: FakeAgentClient())

    results = await _call(mcp, "search_plans", {"query": "a plan for the mcp facade"})

    assert len(results) == 1
    assert results[0]["name"] == "mcp_demo_plan"
    assert results[0]["similarity"] > 0.75

    row = await db_session.get(PlanEmbedding, "mcp_demo_plan")
    await db_session.delete(row)
    await db_session.commit()


async def test_search_plans_returns_empty_for_unrelated_query(db_session, session_factory, tmp_path):
    (tmp_path / "mcp_demo_plan.yaml").write_text(MODULE_PLAN)
    settings = _settings(str(tmp_path), plan_search_threshold=0.75)
    cache = CatalogCache(str(tmp_path))
    embedding_client = FakeEmbeddingClient(
        {
            "mcp_demo_plan: MCP facade test plan": _vec(1.0, 0.0),
            "configure nginx virtual host": _vec(0.0, 0.0, 0.0, 1.0),
        }
    )
    mcp = build_mcp_server(session_factory, settings, cache, embedding_client, client_factory=lambda a, s: FakeAgentClient())

    results = await _call(mcp, "search_plans", {"query": "configure nginx virtual host"})

    assert results == []

    row = await db_session.get(PlanEmbedding, "mcp_demo_plan")
    await db_session.delete(row)
    await db_session.commit()


async def test_get_catalog_unchanged_until_explicit_reload(tmp_path):
    cache = CatalogCache(str(tmp_path))
    before = cache.catalog_markdown
    (tmp_path / "new_plan.yaml").write_text("name: new_plan\nsteps:\n  - name: s\n    ansible.builtin.copy: {}\n")

    assert cache.catalog_markdown == before  # a new file on disk does not change the cached text
    after = cache.reload()
    assert after != before
    assert "new_plan" in after


async def test_run_plan_writes_real_plan_run_and_uses_current_identity(db_session, session_factory, tmp_path):
    (tmp_path / "mcp_demo_plan.yaml").write_text(MODULE_PLAN)
    agent = await _make_agent(db_session)
    settings = _settings(str(tmp_path))
    fake = FakeAgentClient()
    mcp = build_mcp_server(session_factory, settings, CatalogCache(str(tmp_path)), FakeEmbeddingClient(), client_factory=lambda a, s: fake)

    reset = current_identity.set("mcp-caller-token")
    try:
        result = await _call(mcp, "run_plan", {"plan": "mcp_demo_plan", "host": agent.name, "params": {"message": "hi"}})
    finally:
        current_identity.reset(reset)

    assert result["status"] == "succeeded"
    assert fake.tool_calls == [("copy", {"dest": "/etc/motd", "content": "hi"})]

    run = await db_session.get(PlanRun, uuid.UUID(result["plan_run_id"]))
    assert run is not None
    assert run.requested_by == "mcp-caller-token"

    await db_session.delete(run)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def test_run_plan_unknown_host_raises(db_session, session_factory, tmp_path):
    (tmp_path / "mcp_demo_plan.yaml").write_text(MODULE_PLAN)
    settings = _settings(str(tmp_path))
    mcp = build_mcp_server(session_factory, settings, CatalogCache(str(tmp_path)), FakeEmbeddingClient(), client_factory=lambda a, s: FakeAgentClient())

    with pytest.raises(ToolError, match="no such host"):
        await mcp.call_tool("run_plan", {"plan": "mcp_demo_plan", "host": "nope", "params": {"message": "hi"}})


async def test_get_plan_run_returns_step_detail(db_session, session_factory, tmp_path):
    agent = await _make_agent(db_session)
    run = PlanRun(plan_name="demo", agent_id=agent.id, params={"message": "hi"}, dry_run=False, status="succeeded")
    db_session.add(run)
    await db_session.flush()
    await db_session.commit()

    settings = _settings(str(tmp_path))
    mcp = build_mcp_server(session_factory, settings, CatalogCache(str(tmp_path)), FakeEmbeddingClient(), client_factory=lambda a, s: FakeAgentClient())

    detail = await _call(mcp, "get_plan_run", {"plan_run_id": str(run.id)})

    assert detail["plan_run_id"] == str(run.id)
    assert detail["status"] == "succeeded"
    assert detail["steps"] == []

    await db_session.delete(run)
    await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


async def test_get_plan_run_unknown_id_raises(db_session, session_factory, tmp_path):
    settings = _settings(str(tmp_path))
    mcp = build_mcp_server(session_factory, settings, CatalogCache(str(tmp_path)), FakeEmbeddingClient(), client_factory=lambda a, s: FakeAgentClient())

    with pytest.raises(ToolError, match="no such plan run"):
        await mcp.call_tool("get_plan_run", {"plan_run_id": str(uuid.uuid4())})


async def test_get_plan_run_invalid_id_raises(session_factory, tmp_path):
    settings = _settings(str(tmp_path))
    mcp = build_mcp_server(session_factory, settings, CatalogCache(str(tmp_path)), FakeEmbeddingClient(), client_factory=lambda a, s: FakeAgentClient())

    with pytest.raises(ToolError, match="not a valid plan run id"):
        await mcp.call_tool("get_plan_run", {"plan_run_id": "not-a-uuid"})
