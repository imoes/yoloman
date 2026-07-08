"""Tests for the L4 desired-state delivery pipeline — the reconciler
(enqueue → process_outbox → delivery) at the service level, and the
agent-facing pull/ack endpoints over real HTTP. See tests/conftest.py.
"""

import uuid
from uuid import UUID

from fastapi.testclient import TestClient
from sqlalchemy import select

from bossman.db.models import (
    Agent,
    AgentAck,
    AgentConfigDelivery,
    ControllerOutbox,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OrchestrationPlanVersion,
)
from bossman.main import create_app
from bossman.services.reconciler import enqueue_policy_event, process_outbox_once

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


async def _agent(db_session, **overrides) -> Agent:
    fields = {
        "name": f"recon-{uuid.uuid4().hex[:8]}", "token": f"tok-{uuid.uuid4().hex}",
        "mode": "standalone", "enrollment_state": "enrolled", "tenant_id": DEFAULT_TENANT_ID,
    }
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _plan_linked_to_host(db_session, agent, checks):
    plan = OrchestrationPlan(
        id=uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, name=f"plan-{uuid.uuid4().hex[:8]}",
        display_name="P", plan_type="role", current_version=1,
    )
    db_session.add(plan)
    db_session.add(OrchestrationPlanVersion(
        id=uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan.id, version=1,
        generated_monitoring={"checks": checks, "thresholds": {}},
    ))
    db_session.add(OrchestrationPlanLink(
        id=uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, plan_id=plan.id, target_type="host",
        agent_id=agent.id, status="active",
    ))
    await db_session.commit()
    return plan


async def _cleanup(db_session, *objs):
    for o in objs:
        got = await db_session.get(type(o), o.id)
        if got is not None:
            await db_session.delete(got)
    await db_session.commit()


# ---------------------------------------------------------------------------
# Reconciler service pipeline


async def test_enqueue_then_process_creates_delivery(db_session):
    agent = await _agent(db_session)
    plan = await _plan_linked_to_host(db_session, agent, ["docker_daemon"])

    # Enqueue a change targeting this host, then drain the outbox.
    await enqueue_policy_event(db_session, DEFAULT_TENANT_ID, "rule_changed", agent_ids=[agent.id])
    await db_session.commit()

    stats = await process_outbox_once(db_session)
    assert stats.processed >= 1
    assert stats.delivered >= 1

    delivery = await db_session.scalar(
        select(AgentConfigDelivery).where(AgentConfigDelivery.agent_id == agent.id)
    )
    assert delivery is not None
    assert delivery.status == "pending"

    # The outbox row is now done.
    outbox = (await db_session.scalars(select(ControllerOutbox).where(ControllerOutbox.tenant_id == DEFAULT_TENANT_ID))).all()
    assert any(o.status == "done" for o in outbox)

    # cleanup
    await db_session.delete(delivery)
    for o in outbox:
        if o.status == "done":
            await db_session.delete(o)
    await db_session.commit()
    await _cleanup(db_session, plan, agent)


async def test_process_outbox_idempotent_delivery(db_session):
    agent = await _agent(db_session)
    plan = await _plan_linked_to_host(db_session, agent, ["x"])
    await enqueue_policy_event(db_session, DEFAULT_TENANT_ID, "rule_changed", agent_ids=[agent.id])
    await db_session.commit()
    await process_outbox_once(db_session)

    # A second enqueue+process for an unchanged desired state must NOT create
    # a duplicate delivery (same generation, hash unchanged).
    await enqueue_policy_event(db_session, DEFAULT_TENANT_ID, "rule_changed", agent_ids=[agent.id])
    await db_session.commit()
    await process_outbox_once(db_session)

    deliveries = (await db_session.scalars(select(AgentConfigDelivery).where(AgentConfigDelivery.agent_id == agent.id))).all()
    assert len(deliveries) == 1

    for d in deliveries:
        await db_session.delete(d)
    for o in (await db_session.scalars(select(ControllerOutbox).where(ControllerOutbox.tenant_id == DEFAULT_TENANT_ID))).all():
        await db_session.delete(o)
    await db_session.commit()
    await _cleanup(db_session, plan, agent)


# ---------------------------------------------------------------------------
# Agent-facing pull / ack endpoints


async def test_agent_pulls_desired_state_and_acks(db_session):
    agent = await _agent(db_session, token=f"pulltok-{uuid.uuid4().hex}")
    plan = await _plan_linked_to_host(db_session, agent, ["docker_daemon"])
    headers = {"Authorization": f"Bearer {agent.token}"}

    with TestClient(create_app()) as client:
        resp = client.get("/api/agent/v1/desired-state", headers=headers)
        assert resp.status_code == 200
        body = resp.json()
        assert body["agent_id"] == str(agent.id)
        assert "docker_daemon" in body["state"]["monitoring"]["checks"]
        gen, chash = body["generation"], body["config_hash"]

        # Re-pull with the current hash → 304 (nothing changed).
        again = client.get(f"/api/agent/v1/desired-state?current_hash={chash}", headers=headers)
        assert again.status_code == 304

        # Ack the generation.
        ack = client.post("/api/agent/v1/ack", json={"generation": gen, "result": "ack"}, headers=headers)
        assert ack.status_code == 200

    delivery = await db_session.scalar(select(AgentConfigDelivery).where(AgentConfigDelivery.agent_id == agent.id))
    assert delivery.status == "acked"
    ack_row = await db_session.scalar(select(AgentAck).where(AgentAck.agent_id == agent.id))
    assert ack_row.result == "ack"

    await db_session.delete(ack_row)
    await db_session.delete(delivery)
    await db_session.commit()
    await _cleanup(db_session, plan, agent)


async def test_agent_endpoint_rejects_bad_token(db_session):
    with TestClient(create_app()) as client:
        resp = client.get("/api/agent/v1/desired-state", headers={"Authorization": "Bearer nonsense-token"})
    assert resp.status_code == 401


async def test_agent_nack_records_error(db_session):
    agent = await _agent(db_session, token=f"nacktok-{uuid.uuid4().hex}")
    plan = await _plan_linked_to_host(db_session, agent, ["x"])
    headers = {"Authorization": f"Bearer {agent.token}"}
    with TestClient(create_app()) as client:
        body = client.get("/api/agent/v1/desired-state", headers=headers).json()
        client.post(
            "/api/agent/v1/ack",
            json={"generation": body["generation"], "result": "nack", "detail": {"error": "schema mismatch"}},
            headers=headers,
        )
    delivery = await db_session.scalar(select(AgentConfigDelivery).where(AgentConfigDelivery.agent_id == agent.id))
    assert delivery.status == "nacked"
    assert "schema mismatch" in (delivery.last_error or "")

    ack_row = await db_session.scalar(select(AgentAck).where(AgentAck.agent_id == agent.id))
    await db_session.delete(ack_row)
    await db_session.delete(delivery)
    await db_session.commit()
    await _cleanup(db_session, plan, agent)
