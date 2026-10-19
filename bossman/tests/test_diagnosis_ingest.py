"""Bossman's side of the diagnosis (plan B8): ask the agent, check the document again, keep it — DB-backed.

The golden documents (configs/schemas/diagnosis.examples/) stand in for what the agents send; a Windows and a Linux
document go through the same code path. A document that does not hold is stored as a violation with its reasons and
is NOT changed; an agent without the module is a named refusal.
"""

import copy
import json
from pathlib import Path

import pytest
from mcp.server.fastmcp.exceptions import ToolError
from sqlalchemy import select

from bossman.db.models import Diagnosis
from bossman.mcp.server import build_mcp_server
from bossman.services.agent_client import AgentClientError
from bossman.services.catalog import CatalogCache
from tests.test_mcp_server import FakeEmbeddingClient, _call, _make_agent, _settings, session_factory  # noqa: F401

EXAMPLES = Path(__file__).resolve().parents[2] / "configs/schemas/diagnosis.examples"


def golden(name: str) -> dict:
    return json.loads((EXAMPLES / f"{name}.json").read_text())


class DiagnosingAgent:
    """Answers service_diagnose with a fixed document (or refuses as an agent without the module does)."""

    def __init__(self, doc: dict | None = None, missing: bool = False):
        self.doc, self.missing, self.calls = doc, missing, []

    async def call_tool(self, name, body):
        self.calls.append((name, body))
        if self.missing:
            raise AgentClientError(f"10.0.0.7:8010: tool {name!r} returned 404: unknown tool", status=404)
        return {"changed": False, "data": {"diagnosis": self.doc}}


def _mcp(tmp_path, session_factory, client):  # noqa: F811
    return build_mcp_server(session_factory, _settings(str(tmp_path)), CatalogCache(str(tmp_path)), FakeEmbeddingClient(),
                            client_factory=lambda a, s: client)


@pytest.mark.parametrize("example,platform,rule", [
    ("windows-logon-right", "windows", "svc.logon_right_missing"),
    ("linux-203-exec", "linux", "svc.image_missing"),
])
async def test_a_document_that_holds_is_stored_once_through_the_same_path(db_session, session_factory, tmp_path,  # noqa: F811
                                                                          example, platform, rule):
    agent = await _make_agent(db_session)
    doc = golden(example)
    client = DiagnosingAgent(doc)
    mcp = _mcp(tmp_path, session_factory, client)

    out = await _call(mcp, "diagnose_service", {"host": agent.name, "name": doc["target"]["name"]})
    again = await _call(mcp, "diagnose_service", {"host": agent.name, "name": doc["target"]["name"]})

    assert client.calls[0] == ("service_diagnose", {"name": doc["target"]["name"]})
    assert out["contract_status"] == "ok" and out["contract_violations"] == []
    assert (out["platform"], out["leading_rule"]) == (platform, rule)
    assert out["diagnosis"] == doc                        # kept exactly as the agent sent it
    assert again["id"] == out["id"]                        # the same run arriving twice is one row
    rows = (await db_session.scalars(select(Diagnosis).where(Diagnosis.agent_id == agent.id))).all()
    assert len(rows) == 1
    listed = await _call(mcp, "recent_diagnoses", {"host": agent.name})
    assert [i["leading_rule"] for i in listed["items"]] == [rule] and "diagnosis" not in listed["items"][0]
    await db_session.delete(agent)
    await db_session.commit()


async def test_a_document_that_does_not_hold_is_kept_as_a_violation_and_never_repaired(db_session, session_factory, tmp_path):  # noqa: F811
    agent = await _make_agent(db_session)
    doc = golden("unknown-gap")
    bad = copy.deepcopy(doc)
    bad["diagnosis_id"] = "violating-run"
    bad["findings"][0]["certainty"] = "Proven"             # svc.unexplained may never be Proven
    bad["findings"][0]["evidence_ids"].append("evt:System:7000:999999")   # and cites a measurement that is not there
    mcp = _mcp(tmp_path, session_factory, DiagnosingAgent(bad))

    out = await _call(mcp, "diagnose_service", {"host": agent.name, "name": bad["target"]["name"]})

    assert out["contract_status"] == "violation"
    assert any("exceeds the rule's maximum" in v for v in out["contract_violations"])
    assert any("evt:System:7000:999999" in v for v in out["contract_violations"])
    assert out["diagnosis"]["findings"][0]["certainty"] == "Proven"   # stored as sent, not "corrected"
    assert out["leading_certainty"] == "Proven"
    await db_session.delete(agent)
    await db_session.commit()


async def test_an_agent_without_the_module_is_a_named_refusal(db_session, session_factory, tmp_path):  # noqa: F811
    agent = await _make_agent(db_session, agent_version="0.57.40")
    mcp = _mcp(tmp_path, session_factory, DiagnosingAgent(missing=True))

    with pytest.raises(ToolError) as e:
        await mcp.call_tool("diagnose_service", {"host": agent.name, "name": "nginx"})

    assert "has no service_diagnose module" in str(e.value) and "0.57.40" in str(e.value)
    assert (await db_session.scalars(select(Diagnosis).where(Diagnosis.agent_id == agent.id))).first() is None
    await db_session.delete(agent)
    await db_session.commit()


async def test_an_answer_without_a_document_is_named(db_session, session_factory, tmp_path):  # noqa: F811
    agent = await _make_agent(db_session)
    mcp = _mcp(tmp_path, session_factory, DiagnosingAgent(doc=None))

    with pytest.raises(ToolError) as e:
        await mcp.call_tool("diagnose_service", {"host": agent.name, "name": "nginx"})

    assert "without a diagnosis document" in str(e.value)
    await db_session.delete(agent)
    await db_session.commit()


async def test_a_stored_diagnosis_exports_through_mcp(db_session, session_factory, tmp_path):  # noqa: F811
    agent = await _make_agent(db_session)
    doc = golden("windows-dependency")
    mcp = _mcp(tmp_path, session_factory, DiagnosingAgent(doc))
    stored = await _call(mcp, "diagnose_service", {"host": agent.name, "name": doc["target"]["name"]})

    cmk = await _call(mcp, "export_diagnosis", {"id": stored["id"], "format": "checkmk"})
    ps = await _call(mcp, "export_diagnosis", {"id": stored["id"], "format": "powershell"})

    assert cmk["content"].startswith("<<<local>>>\n2 ")
    assert "sc.exe config 'yoloman-probe-base' start= demand" in ps["apply"]
    with pytest.raises(ToolError):
        await mcp.call_tool("export_diagnosis", {"id": stored["id"], "format": "pdf"})
    await db_session.delete(agent)
    await db_session.commit()


async def test_mcp_checks_an_explanation_the_caller_wrote(db_session, session_factory, tmp_path):  # noqa: F811
    agent = await _make_agent(db_session)
    doc = golden("windows-dependency")
    mcp = _mcp(tmp_path, session_factory, DiagnosingAgent(doc))
    stored = await _call(mcp, "diagnose_service", {"host": agent.name, "name": doc["target"]["name"]})
    cited = doc["findings"][0]["evidence_ids"]

    out = await _call(mcp, "check_explanation", {"id": stored["id"], "sentences": [
        {"text": doc["findings"][0]["claim"], "evidence_ids": cited},
        {"text": "It probably failed with error 1067.", "evidence_ids": cited},
    ]})

    assert [s["backed"] for s in out["sentences"]] == [True, False]
    assert "states a certainty" in out["sentences"][1]["why"] and "1067" in out["sentences"][1]["why"]
    assert out["unbacked"] == 1 and out["header"][0].startswith("Proven: ")
    await db_session.delete(agent)
    await db_session.commit()


async def test_send_diagnosis_gelf_tool(db_session, session_factory, tmp_path):  # noqa: F811
    """The MCP tool send_diagnosis_gelf puts a stored diagnosis on the wire; a local UDP socket stands in for Graylog.
    With no target it refuses (never a silent drop)."""
    import socket as _socket
    from bossman.services.catalog import CatalogCache as _CC

    agent = await _make_agent(db_session)
    doc = golden("windows-logon-right")
    client = DiagnosingAgent(doc)

    # Store the diagnosis once (default settings, GELF off).
    mcp_off = build_mcp_server(session_factory, _settings(str(tmp_path)), _CC(str(tmp_path)), FakeEmbeddingClient(),
                               client_factory=lambda a, s: client)
    stored = await _call(mcp_off, "diagnose_service", {"host": agent.name, "name": doc["target"]["name"]})
    row_id = stored["id"]
    with pytest.raises(ToolError, match="BOSSMAN_GELF_HOST"):
        await _call(mcp_off, "send_diagnosis_gelf", {"id": row_id})

    # With a target configured, it sends and the datagrams arrive.
    srv = _socket.socket(_socket.AF_INET, _socket.SOCK_DGRAM)
    srv.bind(("127.0.0.1", 0))
    srv.settimeout(5)
    port = srv.getsockname()[1]
    try:
        mcp_on = build_mcp_server(session_factory,
                                  _settings(str(tmp_path), gelf_host="127.0.0.1", gelf_port=port, gelf_protocol="udp"),
                                  _CC(str(tmp_path)), FakeEmbeddingClient(), client_factory=lambda a, s: client)
        res = await _call(mcp_on, "send_diagnosis_gelf", {"id": row_id})
        assert res["sent"] == res["datagrams"] and res["sent"] >= 1
        got = [json.loads(srv.recvfrom(65535)[0]) for _ in range(res["datagrams"])]
        assert {m["_correlation_id"] for m in got} == {doc["diagnosis_id"]}
    finally:
        srv.close()


async def test_update_diagnosis_is_asked_checked_and_stored(db_session, session_factory, tmp_path):  # noqa: F811
    """diagnose_updates asks the host's update_diagnose, checks the document and keeps it (target kind "updates")."""
    agent = await _make_agent(db_session)
    doc = golden("windows-update-failed")
    client = DiagnosingAgent(doc)
    mcp = _mcp(tmp_path, session_factory, client)

    out = await _call(mcp, "diagnose_updates", {"host": agent.name})
    assert client.calls[0] == ("update_diagnose", {})          # no target name, the whole host's updates
    assert out["target"]["kind"] == "updates"
    assert out["contract_status"] == "ok" and out["contract_violations"] == []
    assert out["leading_rule"] == "upd.install_failed"
    assert out["diagnosis"] == doc

    rows = (await db_session.scalars(select(Diagnosis).where(Diagnosis.agent_id == agent.id))).all()
    assert len(rows) == 1 and rows[0].target_kind == "updates"
    await db_session.delete(agent)
    await db_session.commit()


async def test_diagnose_updates_names_an_agent_without_the_module(db_session, session_factory, tmp_path):  # noqa: F811
    agent = await _make_agent(db_session)
    client = DiagnosingAgent(missing=True)
    mcp = _mcp(tmp_path, session_factory, client)
    with pytest.raises(ToolError, match="no update_diagnose module"):
        await _call(mcp, "diagnose_updates", {"host": agent.name})
    await db_session.delete(agent)
    await db_session.commit()
