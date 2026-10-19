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


class IncidentRingAgent:
    """Answers recent_incidents with a fixed ring (or refuses as an agent without the module does)."""

    def __init__(self, ring: dict | None = None, missing: bool = False):
        self.ring, self.missing, self.calls = ring, missing, []

    async def call_tool(self, name, body):
        self.calls.append((name, body))
        if self.missing:
            raise AgentClientError(f"10.0.0.7:8010: tool {name!r} returned 404: unknown tool", status=404)
        return {"changed": False, "data": self.ring}


async def test_recent_incidents_is_a_live_read_passed_through_with_the_host(db_session, session_factory, tmp_path):  # noqa: F811
    """recent_incidents asks the host's ring live (nothing stored) and returns it with host + agent_version added."""
    agent = await _make_agent(db_session)
    ring = {"source": "ebpf-incident-ring", "persistent": False, "since": "2026-10-19T10:00:00Z",
            "capacity": 1000, "ring_state": "available", "count": 1,
            "incidents": [{"kind": "oom-kill", "at": "2026-10-19T11:30:00Z", "pid": 42, "image": "/usr/bin/svc-a",
                           "source": "ebpf", "evidence_id": "incident:oom:42:1760871000"}]}
    client = IncidentRingAgent(ring)
    mcp = _mcp(tmp_path, session_factory, client)

    out = await _call(mcp, "recent_incidents", {"host": agent.name, "kind": "oom-kill", "within_minutes": 60})
    assert client.calls[0] == ("recent_incidents", {"kind": "oom-kill", "within_minutes": 60, "limit": 200})
    assert out["host"] == agent.name and out["agent_version"] == agent.agent_version
    assert out["ring_state"] == "available" and out["count"] == 1
    assert out["incidents"][0]["evidence_id"] == "incident:oom:42:1760871000"

    rows = (await db_session.scalars(select(Diagnosis).where(Diagnosis.agent_id == agent.id))).all()
    assert rows == []                                         # a live read keeps nothing
    await db_session.delete(agent)
    await db_session.commit()


async def test_recent_incidents_names_an_agent_without_the_module(db_session, session_factory, tmp_path):  # noqa: F811
    agent = await _make_agent(db_session)
    client = IncidentRingAgent(missing=True)
    mcp = _mcp(tmp_path, session_factory, client)
    with pytest.raises(ToolError, match="no recent_incidents module"):
        await _call(mcp, "recent_incidents", {"host": agent.name})
    await db_session.delete(agent)
    await db_session.commit()


async def test_recent_diagnoses_fleet_lists_across_hosts_and_filters(db_session, session_factory, tmp_path):  # noqa: F811
    """recent_diagnoses_fleet scans stored diagnoses across the WHOLE fleet, newest first, and filters by
    contract_status (to surface documents that did not hold)."""
    a1 = await _make_agent(db_session)
    a2 = await _make_agent(db_session)
    # A clean Linux doc on a1 and a (violating) doc on a2, both stored through the real path.
    good = golden("linux-203-exec")
    await _call(_mcp(tmp_path, session_factory, DiagnosingAgent(good)), "diagnose_service",
                {"host": a1.name, "name": good["target"]["name"]})
    bad = copy.deepcopy(golden("unknown-gap"))
    bad["diagnosis_id"] = "fleet-violating-run"
    bad["findings"][0]["certainty"] = "Proven"                 # svc.unexplained may never be Proven -> violation
    await _call(_mcp(tmp_path, session_factory, DiagnosingAgent(bad)), "diagnose_service",
                {"host": a2.name, "name": bad["target"]["name"]})

    mcp = _mcp(tmp_path, session_factory, DiagnosingAgent())
    # Scope by the unique host name (q matches host/service/rule) so the assertion is robust on the shared DB, which
    # holds the real fleet's diagnoses too. Both hosts are findable fleet-wide, and the list carries no documents.
    r1 = await _call(mcp, "recent_diagnoses_fleet", {"q": a1.name})
    r2 = await _call(mcp, "recent_diagnoses_fleet", {"q": a2.name})
    assert r1["items"] and all(i["host"] == a1.name for i in r1["items"])
    assert r2["items"] and all(i["host"] == a2.name for i in r2["items"])
    assert "diagnosis" not in r1["items"][0]                   # no documents in the list

    # The violating doc on a2 is surfaced by the contract_status filter (scoped to a2 to stay robust on the shared DB).
    violations = await _call(mcp, "recent_diagnoses_fleet", {"contract_status": "violation", "q": a2.name})
    assert violations["items"] and all(i["contract_status"] == "violation" for i in violations["items"])
    assert a2.name in {i["host"] for i in violations["items"]}

    for a in (a1, a2):
        await db_session.delete(a)
    await db_session.commit()


async def test_related_finds_the_same_failure_mode_across_hosts(db_session, session_factory, tmp_path):  # noqa: F811
    """diag.related returns other diagnoses with the SAME leading rule (the precedent lens), across hosts, excluding
    self. A unique rule id keeps the assertion robust on the shared DB."""
    from sqlalchemy import select as _select

    from bossman.db.models import Diagnosis
    from bossman.services import diagnosis as diag

    a1 = await _make_agent(db_session)
    a2 = await _make_agent(db_session)
    import uuid as _uuid
    uniq = f"svc.rel-{_uuid.uuid4().hex[:8]}"
    for a, run in ((a1, "rel-run-1"), (a2, "rel-run-2")):
        doc = copy.deepcopy(golden("linux-203-exec"))
        doc["diagnosis_id"] = f"{run}-{uniq}"
        doc["findings"][0]["rule_id"] = uniq
        await _call(_mcp(tmp_path, session_factory, DiagnosingAgent(doc)), "diagnose_service",
                    {"host": a.name, "name": doc["target"]["name"]})

    row1 = await db_session.scalar(_select(Diagnosis).where(Diagnosis.agent_id == a1.id, Diagnosis.leading_rule == uniq))
    rel = await diag.related(db_session, row1)
    assert {r.host for r in rel} == {a2.name}                      # the other host's same-failure diagnosis, not self
    assert all(r.leading_rule == uniq for r in rel)

    # A diagnosis with no leading rule has no failure mode to match.
    row1.leading_rule = None
    assert await diag.related(db_session, row1) == []

    for a in (a1, a2):
        await db_session.delete(a)
    await db_session.commit()


async def test_recurring_groups_by_failure_mode(db_session, session_factory, tmp_path):  # noqa: F811
    """diag.recurring groups stored diagnoses by leading rule with count + distinct-host + violation counts. A unique
    rule across two hosts keeps the assertion robust on the shared DB."""
    import uuid as _uuid

    from bossman.services import diagnosis as diag

    a1 = await _make_agent(db_session)
    a2 = await _make_agent(db_session)
    uniq = f"svc.recur-{_uuid.uuid4().hex[:8]}"
    for a, run in ((a1, "r1"), (a2, "r2")):
        doc = copy.deepcopy(golden("linux-203-exec"))
        doc["diagnosis_id"] = f"{run}-{uniq}"
        doc["findings"][0]["rule_id"] = uniq
        await _call(_mcp(tmp_path, session_factory, DiagnosingAgent(doc)), "diagnose_service",
                    {"host": a.name, "name": doc["target"]["name"]})

    rows = await diag.recurring(db_session, limit=200)
    mine = [r for r in rows if r["rule"] == uniq]
    assert len(mine) == 1
    assert mine[0]["count"] == 2 and mine[0]["hosts"] == 2       # two occurrences across two distinct hosts
    # No leading rule is not a failure mode — such diagnoses never appear here.
    assert all(r["rule"] is not None for r in rows)

    for a in (a1, a2):
        await db_session.delete(a)
    await db_session.commit()


async def test_for_diagnosis_links_remedy_proposals(db_session, session_factory, tmp_path):  # noqa: F811
    """proposals.for_diagnosis finds the remedy proposals stamped with a diagnosis's row id — the diagnosis→action
    loop. A proposal for a different diagnosis is not returned."""
    from bossman.db.models import DEFAULT_TENANT_ID, ChangeProposal
    from bossman.services import proposals as proposals_svc

    agent = await _make_agent(db_session)
    doc = golden("windows-logon-right")
    stored = await _call(_mcp(tmp_path, session_factory, DiagnosingAgent(doc)), "diagnose_service",
                         {"host": agent.name, "name": doc["target"]["name"]})
    rid = stored["id"]

    p = ChangeProposal(tenant_id=DEFAULT_TENANT_ID, kind="remedy", agent_id=agent.id, host=agent.name,
                       title="fix it", status="pending", requested_by="ai:test",
                       payload={"diagnosis_row_id": rid, "finding": 0})
    other = ChangeProposal(tenant_id=DEFAULT_TENANT_ID, kind="remedy", agent_id=agent.id, host=agent.name,
                           title="unrelated", status="pending", requested_by="ai:test",
                           payload={"diagnosis_row_id": "00000000-0000-0000-0000-000000000000", "finding": 0})
    db_session.add_all([p, other])
    await db_session.commit()

    import uuid as _uuid
    found = await proposals_svc.for_diagnosis(db_session, _uuid.UUID(rid))
    assert [str(x.id) for x in found] == [str(p.id)]            # exactly the one stamped with this diagnosis

    await db_session.delete(p)
    await db_session.delete(other)
    await db_session.delete(agent)
    await db_session.commit()
