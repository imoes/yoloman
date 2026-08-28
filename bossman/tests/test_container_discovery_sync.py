"""The monitored-container allow-list pushed to the agent after discover/apply.

The property that matters: the agent is given the COMPLETE set of monitored containers (it replaces its
list wholesale), computed from the DiscoveredService rows — never a partial or a stale set. A push
failure is reported, not fatal, because the operator's decision is already persisted.
"""

from __future__ import annotations

import uuid
from tests.naming import owned_name

import pytest

from bossman.api.checks import DEFAULT_TENANT_ID, _sync_monitored_containers
from bossman.db.models import Agent, DiscoveredService
from bossman.services.discovery import CONTAINER_CHECK_NAME


def _hex_name() -> str:
    # <prefix>-<8 hex> so the conftest residue guard cleans the agent (and its cascaded rows) up.
    return owned_name("cont")


async def _make_agent(session, address="host.example:8010"):
    agent = Agent(name=_hex_name(), address=address, token="t", agent_metadata={})
    session.add(agent)
    await session.flush()
    return agent


def _fake_factory(captured: dict, *, fail: str | None = None):
    class _Client:
        def __init__(self, agent, settings):
            pass

        async def set_collect_config(self, patch):
            if fail:
                from bossman.services.agent_client import AgentClientError

                raise AgentClientError(fail)
            captured["patch"] = patch
            return {"status": "accepted", "changed": patch}

    return lambda agent, settings: _Client(agent, settings)


@pytest.mark.asyncio
async def test_sync_pushes_only_monitored_containers_as_full_set(db_session):
    agent = await _make_agent(db_session)
    # Two monitored containers, one undecided (offered, not accepted), and an unrelated real check —
    # only the two monitored container items may be pushed.
    db_session.add_all([
        DiscoveredService(tenant_id=DEFAULT_TENANT_ID, agent_id=agent.id, check_name=CONTAINER_CHECK_NAME, item="web", state="monitored"),
        DiscoveredService(tenant_id=DEFAULT_TENANT_ID, agent_id=agent.id, check_name=CONTAINER_CHECK_NAME, item="db", state="monitored"),
        DiscoveredService(tenant_id=DEFAULT_TENANT_ID, agent_id=agent.id, check_name=CONTAINER_CHECK_NAME, item="redis", state="undecided"),
        DiscoveredService(tenant_id=DEFAULT_TENANT_ID, agent_id=agent.id, check_name="CPU load", item="", state="monitored"),
    ])
    await db_session.flush()

    captured: dict = {}
    out = await _sync_monitored_containers(db_session, object(), _fake_factory(captured), agent)

    assert out["pushed"] is True
    assert captured["patch"] == {"monitored_containers": ["db", "web"]}  # sorted, only monitored containers
    assert out["containers"] == ["db", "web"]


@pytest.mark.asyncio
async def test_sync_with_nothing_monitored_pushes_empty_list(db_session):
    # Removing the last container must push [] — "un-monitor everything" — not skip the push.
    agent = await _make_agent(db_session)
    db_session.add(DiscoveredService(tenant_id=DEFAULT_TENANT_ID, agent_id=agent.id, check_name=CONTAINER_CHECK_NAME, item="web", state="undecided"))
    await db_session.flush()

    captured: dict = {}
    out = await _sync_monitored_containers(db_session, object(), _fake_factory(captured), agent)
    assert out["pushed"] is True
    assert captured["patch"] == {"monitored_containers": []}


@pytest.mark.asyncio
async def test_sync_reports_push_failure_without_raising(db_session):
    agent = await _make_agent(db_session)
    db_session.add(DiscoveredService(tenant_id=DEFAULT_TENANT_ID, agent_id=agent.id, check_name=CONTAINER_CHECK_NAME, item="web", state="monitored"))
    await db_session.flush()

    out = await _sync_monitored_containers(db_session, object(), _fake_factory({}, fail="agent unreachable"), agent)
    assert out["pushed"] is False
    assert "agent unreachable" in out["reason"]
    assert out["containers"] == ["web"]  # the desired set is still reported, so a retry knows it


@pytest.mark.asyncio
async def test_sync_skips_push_when_agent_has_no_address(db_session):
    agent = await _make_agent(db_session, address=None)
    db_session.add(DiscoveredService(tenant_id=DEFAULT_TENANT_ID, agent_id=agent.id, check_name=CONTAINER_CHECK_NAME, item="web", state="monitored"))
    await db_session.flush()

    out = await _sync_monitored_containers(db_session, object(), _fake_factory({}), agent)
    assert out["pushed"] is False
    assert "address" in out["reason"]
