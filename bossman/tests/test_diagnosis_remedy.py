"""A diagnosis remedy as a change proposal (plan B10) — DB-backed.

The rules under test: the preview carries what a reviewer needs; the proposer cannot approve (four-eyes, and the
reason is shown BEFORE the click); approving records and attaches the artifacts but never reaches the host; a
finding without a remedy and a document that does not hold are refused with the reason.
"""

import copy
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from bossman.db.models import AccessGrant, ChangeProposal
from bossman.main import create_app
from bossman.services import proposals
from bossman.services.auth import new_api_token
from bossman.services.diagnosis import store
from tests.test_mcp_server import FakeEmbeddingClient, _call, _make_agent, _settings, session_factory  # noqa: F401

EXAMPLES = Path(__file__).resolve().parents[2] / "configs/schemas/diagnosis.examples"


def golden(name: str) -> dict:
    return json.loads((EXAMPLES / f"{name}.json").read_text())


def no_agent(*_a, **_k):
    raise AssertionError("approving a remedy must not reach the host")


async def _stored(db_session, agent, name="windows-logon-right", mod=None):
    doc = copy.deepcopy(golden(name))
    if mod:
        mod(doc)
    return await store(db_session, agent, doc)


async def test_the_preview_carries_claim_evidence_rollback_and_the_exports(db_session):
    agent = await _make_agent(db_session)
    row = await _stored(db_session, agent)
    p = await proposals.create_remedy_proposal(db_session, row, 0, "alice")

    assert (p.kind, p.status, p.payload["rule_id"]) == ("remedy", "pending", "svc.logon_right_missing")
    assert [e["id"] for e in p.preview["evidence"]] == p.payload["evidence_ids"]
    assert p.preview["rollback"]["action"] == "revoke" and p.preview["certainty"] == "Proven"
    assert "ansible.windows.win_user_right" in p.preview["exports"]["ansible"]["apply"]
    assert p.preview["exports"]["dsc"]["not_expressible"]           # named, not missing
    await db_session.delete(p)
    await db_session.delete(agent)
    await db_session.commit()


async def test_the_proposer_cannot_approve_and_approval_executes_nothing(db_session):
    agent = await _make_agent(db_session)
    row = await _stored(db_session, agent)
    p = await proposals.create_remedy_proposal(db_session, row, 0, "alice")

    ok, why = proposals.approvable(p, "alice")
    assert ok is False and "four-eyes" in why
    with pytest.raises(ValueError, match="four-eyes"):
        await proposals.approve(db_session, _settings("/tmp"), no_agent, p.id, "alice")

    done = await proposals.approve(db_session, _settings("/tmp"), no_agent, p.id, "bob")
    assert done.status == "approved" and done.decided_by == "bob"
    assert done.apply_result["executed"] is False and "does not execute" in done.apply_result["reason"]
    assert "powershell" in done.apply_result["artifacts"]
    assert proposals.approvable(done, "carol") == (False, "the proposal is approved, not pending")
    await db_session.delete(done)
    await db_session.delete(agent)
    await db_session.commit()


async def test_no_remedy_and_a_broken_document_are_refused_with_the_reason(db_session):
    agent = await _make_agent(db_session)
    none = await _stored(db_session, agent, "unknown-gap")
    with pytest.raises(ValueError, match="offers no remedy"):
        await proposals.create_remedy_proposal(db_session, none, 0, "alice")
    with pytest.raises(ValueError, match="there is no finding 5"):
        await proposals.create_remedy_proposal(db_session, none, 5, "alice")

    def break_it(d):
        d["diagnosis_id"] = "broken-run"
        d["findings"][0]["evidence_ids"] = ["evt:System:1:1"]
    broken = await _stored(db_session, agent, mod=break_it)
    assert broken.contract_status == "violation"
    with pytest.raises(ValueError, match="does not hold"):
        await proposals.create_remedy_proposal(db_session, broken, 0, "alice")
    await db_session.delete(agent)
    await db_session.commit()


async def _token(db_session, name):
    row, raw = new_api_token(name)
    db_session.add(row)
    await db_session.flush()
    db_session.add(AccessGrant(subject_kind="api_token", subject_ref=name, subject_token_id=row.id, scope="all"))
    await db_session.commit()
    return row, {"Authorization": f"Bearer {raw}"}


async def test_rest_shows_the_greyed_reason_before_the_click_and_a_second_person_approves(db_session):
    agent = await _make_agent(db_session)
    row = await _stored(db_session, agent)
    t1, alice = await _token(db_session, "remedy-alice")
    t2, bob = await _token(db_session, "remedy-bob")
    with TestClient(create_app()) as client:
        made = client.post(f"/api/v1/diagnoses/{row.id}/propose", json={"finding": 0}, headers=alice)
        assert made.status_code == 200, made.text
        pid = made.json()["proposal_id"]
        as_alice = client.get(f"/api/v1/change-proposals/{pid}", headers=alice).json()
        refused = client.post(f"/api/v1/change-proposals/{pid}/approve", headers=alice)
        as_bob = client.get(f"/api/v1/change-proposals/{pid}", headers=bob).json()
        approved = client.post(f"/api/v1/change-proposals/{pid}/approve", headers=bob)

    assert as_alice["can_approve"] is False and "four-eyes" in as_alice["cannot_approve_reason"]
    assert refused.status_code == 409 and "four-eyes" in refused.json()["detail"]
    assert as_bob["can_approve"] is True and as_bob["cannot_approve_reason"] is None
    assert approved.status_code == 200 and approved.json()["status"] == "approved"
    assert approved.json()["apply_result"]["executed"] is False

    await db_session.delete(await db_session.get(ChangeProposal, __import__("uuid").UUID(pid)))
    for x in (t1, t2, agent):
        await db_session.delete(x)
    await db_session.commit()


async def test_mcp_files_an_ai_proposal(db_session, session_factory, tmp_path):  # noqa: F811
    from bossman.mcp.server import build_mcp_server
    from bossman.services.catalog import CatalogCache

    agent = await _make_agent(db_session)
    row = await _stored(db_session, agent, "windows-dependency")
    mcp = build_mcp_server(session_factory, _settings(str(tmp_path)), CatalogCache(str(tmp_path)), FakeEmbeddingClient(),
                           client_factory=no_agent)
    out = await _call(mcp, "propose_remedy", {"id": str(row.id), "finding": 0})

    p = await db_session.get(ChangeProposal, __import__("uuid").UUID(out["proposal_id"]))
    assert p.requested_by.startswith("ai:") and p.payload["rule_id"] == "svc.dependency_failed"
    assert "executes nothing" in out["next"]
    await db_session.delete(p)
    await db_session.delete(agent)
    await db_session.commit()
