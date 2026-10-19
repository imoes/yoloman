"""The diagnosis read-tools exposed to the in-app chat assistant (fleet overview + "what keeps breaking"). DB-only,
read-only — no agent client needed, so they always work in the chat context. Real DB via db_session."""

from bossman.services.chat_tools import TOOL_NAMES, execute_tool


def test_diagnosis_read_tools_registered():
    assert {"recent_diagnoses_fleet", "recurring_failures", "recent_incidents"} <= TOOL_NAMES


async def test_recent_diagnoses_fleet_returns_items(db_session):
    out = await execute_tool(db_session, "recent_diagnoses_fleet", {})
    assert isinstance(out.get("items"), list)                      # shape, not count (shared DB)
    assert all("diagnosis" not in i for i in out["items"])          # list carries no documents


async def test_recurring_failures_returns_grouped_items(db_session):
    out = await execute_tool(db_session, "recurring_failures", {})
    assert isinstance(out.get("items"), list)
    for r in out["items"]:
        assert {"rule", "count", "hosts"} <= set(r) and r["rule"] is not None


async def test_recent_incidents_without_a_host_client_is_a_clean_error(db_session):
    # In a chat context without settings/client_factory, a host-reaching tool refuses with a message, not a crash.
    out = await execute_tool(db_session, "recent_incidents", {"host": "whatever"})
    assert "error" in out
