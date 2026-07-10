"""Block K3 — agentic tool-loop + fleet-tool executor tests."""

import uuid

from bossman.db.models import Agent
from bossman.services.chat_agent import backend_is_agentic, run_agentic
from bossman.services.chat_tools import TOOL_NAMES, execute_tool


class ToolBackend:
    """A fake tool-capable backend: round 1 asks for a tool, round 2 answers."""

    def __init__(self):
        self.round = 0
        self.last_convo = None

    async def complete_with_tools(self, messages, tools, *, model=None):
        self.round += 1
        self.last_convo = messages
        if self.round == 1:
            return {"content": "", "tool_calls": [{"id": "c1", "function": {"name": "fleet_health", "arguments": "{}"}}]}
        return {"content": "There are 3 hosts, all online.", "tool_calls": []}


class PlainBackend:
    async def stream(self, messages, **kw):
        yield {"type": "delta", "text": "hi"}


def test_backend_is_agentic():
    assert backend_is_agentic(ToolBackend()) is True
    assert backend_is_agentic(PlainBackend()) is False


async def test_run_agentic_calls_tool_then_answers():
    calls = []

    async def executor(name, args):
        calls.append((name, args))
        return {"total": 3, "online": 3}

    backend = ToolBackend()
    events = [e async for e in run_agentic(backend, [{"role": "user", "content": "how many hosts?"}], executor)]
    types = [e["type"] for e in events]
    assert types == ["tool_start", "tool_done", "delta"]
    assert events[0]["tool"] == "fleet_health" and events[1]["ok"] is True
    assert events[2]["text"] == "There are 3 hosts, all online."
    assert calls == [("fleet_health", {})]
    # The tool result was fed back into the conversation for round 2.
    assert any(m.get("role") == "tool" for m in backend.last_convo)


async def test_run_agentic_tool_error_feeds_back():
    async def executor(name, args):
        raise RuntimeError("db down")

    events = [e async for e in run_agentic(ToolBackend(), [{"role": "user", "content": "x"}], executor)]
    done = [e for e in events if e["type"] == "tool_done"][0]
    assert done["ok"] is False  # failure surfaced, loop continued


# ---- fleet-tool executor (DB) ----


async def _make_agent(db_session, **kw):
    fields = {"name": f"chat-tool-{uuid.uuid4().hex[:8]}", "token": "t", "mode": "standalone", "enrollment_state": "enrolled"}
    fields.update(kw)
    a = Agent(**fields)
    db_session.add(a)
    await db_session.flush()
    await db_session.commit()
    return a


async def test_execute_tool_list_hosts_and_health(db_session):
    a = await _make_agent(db_session)
    hosts = await execute_tool(db_session, "list_hosts", {})
    assert any(h["name"] == a.name and h["enrollment_state"] == "enrolled" for h in hosts["hosts"])
    health = await execute_tool(db_session, "fleet_health", {})
    assert health["total"] >= 1 and "online" in health and "offline" in health
    await db_session.delete(a)
    await db_session.commit()


async def test_execute_unknown_tool(db_session):
    out = await execute_tool(db_session, "nope", {})
    assert "error" in out
    assert TOOL_NAMES == {"list_hosts", "fleet_health"}
