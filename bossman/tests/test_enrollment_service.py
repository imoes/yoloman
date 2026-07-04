"""Real, DB-backed tests for bossman.services.enrollment — see
tests/conftest.py's db_session fixture (skips if no DB is reachable, never
mocked). These operate below the HTTP layer, directly on the service
function; tests/test_enroll_api.py covers the same logic end to end
through the actual REST route.
"""

import uuid

import pytest
from sqlalchemy import select

from bossman.db.models import Agent
from bossman.services.enrollment import EnrollRequest, InvalidEnrollSecret, enroll_agent


async def test_enroll_agent_creates_new(db_session):
    name = f"svc-new-{uuid.uuid4().hex[:8]}"
    agent = await enroll_agent(
        db_session, "secret", EnrollRequest(name=name, enroll_secret="secret", token="tok", address="1.1.1.1:1")
    )

    assert agent.enrollment_state == "enrolled"
    assert agent.enrolled_at is not None
    assert agent.token == "tok"

    got = await db_session.scalar(select(Agent).where(Agent.name == name))
    assert got is not None


async def test_enroll_agent_updates_existing(db_session):
    name = f"svc-reenroll-{uuid.uuid4().hex[:8]}"
    await enroll_agent(
        db_session, "secret", EnrollRequest(name=name, enroll_secret="secret", token="old", address="1.1.1.1:1")
    )

    agent = await enroll_agent(
        db_session, "secret", EnrollRequest(name=name, enroll_secret="secret", token="new", address="2.2.2.2:2")
    )

    assert agent.token == "new"
    assert agent.address == "2.2.2.2:2"

    matches = (await db_session.scalars(select(Agent).where(Agent.name == name))).all()
    assert len(matches) == 1, "re-enrolling must update the existing row, not create a second one"


async def test_enroll_agent_wrong_secret_rejected(db_session):
    with pytest.raises(InvalidEnrollSecret):
        await enroll_agent(db_session, "correct-secret", EnrollRequest(name="whoever", enroll_secret="wrong", token="t"))

    got = await db_session.scalar(select(Agent).where(Agent.name == "whoever"))
    assert got is None, "a rejected enrollment must not create an agent row"
