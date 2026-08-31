"""Tests for the L4 desired-state delivery pipeline — the reconciler
(enqueue → process_outbox → PUSH to the agent → record ack/nack) at the
service level. L4 is push, not pull: Bossman POSTs each new generation to the
agent's own /api/v1/config/apply, so there is no agent-facing HTTP ingress to
test here. The push itself is exercised with a fake AgentClient so no socket
is opened. See tests/conftest.py.
"""

import pytest
import uuid
from tests.naming import owned_name
from uuid import UUID

from sqlalchemy import select, text

from bossman.config import Settings
from bossman.db.models import (
    Agent,
    AgentAck,
    AgentConfigDelivery,
    ControllerOutbox,
    OrchestrationPlan,
    OrchestrationPlanLink,
    OrchestrationPlanVersion,
)
from bossman.services.agent_client import AgentClientError
from bossman.services.reconciler import enqueue_policy_event, process_outbox_once

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


class FakeAgentClient:
    """Stands in for services.agent_client.AgentClient: records every pushed
    generation and replies like the Go agent's /api/v1/config/apply
    ({"status": "applied", "generation": N}). Set `fail=True` to simulate an
    unreachable/erroring agent."""

    def __init__(self, fail: bool = False):
        self.fail = fail
        self.pushed: list[tuple[int, str, dict]] = []

    async def apply_config(self, generation: int, config_hash: str, state: dict) -> dict:
        if self.fail:
            raise AgentClientError("push failed: connection refused")
        self.pushed.append((generation, config_hash, state))
        return {"status": "applied", "generation": generation}


def _factory(client):
    """A ClientFactory (agent, settings) -> client that always yields the same
    fake, so the test can inspect what was pushed."""

    def make(_agent, _settings):
        return client

    return make


async def _agent(db_session, **overrides) -> Agent:
    fields = {
        "name": owned_name("recon"), "token": f"tok-{uuid.uuid4().hex}",
        "mode": "standalone", "enrollment_state": "enrolled", "tenant_id": DEFAULT_TENANT_ID,
        "address": "10.0.0.9:8443",
    }
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _plan_linked_to_host(db_session, agent, checks):
    plan = OrchestrationPlan(
        id=uuid.uuid4(), tenant_id=DEFAULT_TENANT_ID, name=owned_name("plan"),
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


async def _drain(db_session):
    """Delete every outbox/delivery/ack row for the default tenant — keeps the
    shared dev DB clean between tests."""
    for model in (AgentAck, AgentConfigDelivery, ControllerOutbox):
        for row in (await db_session.scalars(select(model).where(model.tenant_id == DEFAULT_TENANT_ID))).all():
            await db_session.delete(row)
    await db_session.commit()


# ---------------------------------------------------------------------------
# Reconciler push pipeline


async def _live_reconciler_attached(session) -> str | None:
    """Is another process already draining the outbox of THIS database?

    These three tests enqueue an outbox row and then call process_outbox_once themselves. That only
    works if nobody else gets there first — and enqueue_policy_event emits a `pg_notify` on commit BY
    DESIGN, so a running Bossman wakes instantly, takes the row FOR UPDATE, and this test's SKIP
    LOCKED query returns nothing. Measured while the dev stack was up: the row is pending with
    available_at 21 ms in the past, both predicates hold, and the query selects 0 rows.

    So the tests ask first. A named skip beats a red test that means "your dev stack is running": the
    failure it produced said `assert 0 >= 1`, which reads like a broken reconciler and is not one.
    Against a database with no listener — CI, or a stopped stack — they run normally.
    """
    listeners = await session.scalar(text(
        "select count(*) from pg_stat_activity "
        "where datname = current_database() and pid <> pg_backend_pid() "
        "and query like '%LISTEN%bossman_outbox%'"
    ))
    if listeners:
        return (f"{listeners} live reconciler(s) LISTEN on bossman_outbox in this database — they take "
                "the outbox row before this test can (pg_notify wakes them on commit, FOR UPDATE SKIP "
                "LOCKED hides it from us). To run this: `docker compose -p agentic-mcp stop bossman`, "
                "run the file, then `start bossman` (docs/developing.md, section 6).")
    return None


async def test_enqueue_then_process_pushes_and_acks(db_session):
    busy = await _live_reconciler_attached(db_session)
    if busy:
        pytest.skip(busy)
    settings = Settings()
    agent = await _agent(db_session)
    plan = await _plan_linked_to_host(db_session, agent, ["docker_daemon"])
    client = FakeAgentClient()

    await enqueue_policy_event(db_session, DEFAULT_TENANT_ID, "rule_changed", agent_ids=[agent.id])
    await db_session.commit()

    stats = await process_outbox_once(db_session, settings, client_factory=_factory(client))
    assert stats.processed >= 1
    assert stats.delivered >= 1

    # The desired state was actually pushed to the agent, and it carried the
    # compiled checks.
    assert len(client.pushed) == 1
    gen, _chash, state = client.pushed[0]
    assert "docker_daemon" in state["monitoring"]["checks"]

    # The push was acked: delivery 'acked' + an AgentAck('ack').
    delivery = await db_session.scalar(select(AgentConfigDelivery).where(AgentConfigDelivery.agent_id == agent.id))
    assert delivery is not None
    assert delivery.status == "acked"
    assert delivery.generation == gen
    ack = await db_session.scalar(select(AgentAck).where(AgentAck.agent_id == agent.id))
    assert ack is not None and ack.result == "ack"

    # The outbox row is now done.
    outbox = (await db_session.scalars(select(ControllerOutbox).where(ControllerOutbox.tenant_id == DEFAULT_TENANT_ID))).all()
    assert any(o.status == "done" for o in outbox)

    await _drain(db_session)
    await _cleanup(db_session, plan, agent)


async def test_process_outbox_idempotent_no_second_push(db_session):
    busy = await _live_reconciler_attached(db_session)
    if busy:
        pytest.skip(busy)
    settings = Settings()
    agent = await _agent(db_session)
    plan = await _plan_linked_to_host(db_session, agent, ["x"])
    client = FakeAgentClient()

    await enqueue_policy_event(db_session, DEFAULT_TENANT_ID, "rule_changed", agent_ids=[agent.id])
    await db_session.commit()
    await process_outbox_once(db_session, settings, client_factory=_factory(client))

    # A second enqueue+process for an unchanged desired state must NOT push
    # again (same generation, hash unchanged → compiler reports changed=False).
    await enqueue_policy_event(db_session, DEFAULT_TENANT_ID, "rule_changed", agent_ids=[agent.id])
    await db_session.commit()
    await process_outbox_once(db_session, settings, client_factory=_factory(client))

    assert len(client.pushed) == 1
    deliveries = (await db_session.scalars(select(AgentConfigDelivery).where(AgentConfigDelivery.agent_id == agent.id))).all()
    assert len(deliveries) == 1

    await _drain(db_session)
    await _cleanup(db_session, plan, agent)


async def test_push_failure_records_nack(db_session):
    busy = await _live_reconciler_attached(db_session)
    if busy:
        pytest.skip(busy)
    settings = Settings()
    agent = await _agent(db_session)
    plan = await _plan_linked_to_host(db_session, agent, ["docker_daemon"])
    client = FakeAgentClient(fail=True)

    await enqueue_policy_event(db_session, DEFAULT_TENANT_ID, "rule_changed", agent_ids=[agent.id])
    await db_session.commit()

    stats = await process_outbox_once(db_session, settings, client_factory=_factory(client))
    # The outbox row still processed (a failed push must not stall the queue);
    # the delivery carries the failure.
    assert stats.processed >= 1
    assert stats.failed >= 1

    delivery = await db_session.scalar(select(AgentConfigDelivery).where(AgentConfigDelivery.agent_id == agent.id))
    assert delivery is not None
    assert delivery.status == "nacked"
    assert "connection refused" in (delivery.last_error or "")
    ack = await db_session.scalar(select(AgentAck).where(AgentAck.agent_id == agent.id))
    assert ack is not None and ack.result == "nack"

    await _drain(db_session)
    await _cleanup(db_session, plan, agent)
