"""Block G9-P4 — the AI discovery chat tools (discover_host_checks /
assign_host_check). Real DB via db_session; fake agent client."""

import uuid
from tests.naming import owned_name

from bossman.db.models import Agent, CheckAssignment
from bossman.services.chat_tools import TOOL_NAMES, execute_tool

TENANT = "00000000-0000-0000-0000-000000000001"


async def _agent(db_session, address="10.0.0.9:8010"):
    a = Agent(id=uuid.uuid4(), name=owned_name("cd"), token="t", tenant_id=TENANT,
              mode="standalone", enrollment_state="enrolled", address=address)
    db_session.add(a)
    await db_session.flush()
    await db_session.commit()
    return a


def test_discovery_tools_registered():
    assert {"discover_host_checks", "assign_host_check"} <= TOOL_NAMES


async def test_assign_host_check_creates_assignment(db_session):
    a = await _agent(db_session)
    out = await execute_tool(
        db_session, "assign_host_check",
        {"host": a.name, "check_name": "mysql", "parameters": {"user": "monitor", "port": 3306}},
    )
    assert out["assigned"] == "mysql" and out["host"] == a.name
    row = await db_session.scalar(
        __import__("sqlalchemy").select(CheckAssignment).where(CheckAssignment.agent_id == a.id)
    )
    assert row is not None and row.scope_type == "host" and row.source == "ai"
    assert row.parameters == {"user": "monitor", "port": 3306}
    await db_session.delete(row)
    await db_session.delete(a)
    await db_session.commit()


async def test_assign_unknown_host_errors(db_session):
    out = await execute_tool(db_session, "assign_host_check", {"host": "nope-xyz", "check_name": "df"})
    assert "error" in out


async def test_discover_without_client_errors(db_session):
    a = await _agent(db_session)
    # settings/client_factory not wired (read-only chat context) -> graceful error
    out = await execute_tool(db_session, "discover_host_checks", {"host": a.name})
    assert "error" in out
    await db_session.delete(a)
    await db_session.commit()


async def test_discover_runs_with_fake_client(db_session, tmp_path):
    a = await _agent(db_session)

    # a minimal check in a temp checks.d
    (tmp_path / "df.star").write_text("def main(ctx, params): return {}\n", encoding="utf-8")
    (tmp_path / "df.nt").write_text(
        "name: df\nshort_description: Filesystem\noptions:\n  warn:\n    type: int\nwrites: false\nruntime: starlark\nkind: check\n",
        encoding="utf-8",
    )

    class FakeClient:
        """Answers the two phases differently, the way a real agent does.

        Discovery is no longer a single call: the check is asked what exists
        (`params["_discover"]`), then RUN for real against one discovered item, and only an
        item whose run grades OK/WARN/CRIT counts as present (services/discovery._data_present).
        That gate is what stopped placeholder checks — MongoDB on a host without MongoDB —
        from being offered everywhere. A fake that returns the discovery list for BOTH calls
        therefore fails its own probe: the probe reply has no `state`.
        """

        async def push_modules(self, mods):
            return {"results": []}

        async def call_tool(self, name, body):
            if (body or {}).get("_discover"):
                return {"data": {"discovery": [{"item": "/", "params": {}, "metrics": ["used_percent"]}]}}
            # The probe run: a real verdict, with the evidence that a read happened.
            return {"data": {"state": "OK", "summary": "51% used"}, "data_source": {"attempts": 1, "produced": 1}}

    class S:
        checks_dir = str(tmp_path)

    out = await execute_tool(
        db_session, "discover_host_checks", {"host": a.name},
        settings=S(), client_factory=lambda agent, settings: FakeClient(),
    )
    assert out["host"] == a.name
    names = {p["check_name"] for p in out["proposals"]}
    assert "df" in names
    await db_session.delete(a)
    await db_session.commit()
