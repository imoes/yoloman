"""Enrollment business logic (see docs/plan.md's Bossman plan, section
B.3). Kept free of FastAPI imports — reachable from the REST API, a future
MCP facade, and tests without duplicating logic, the same discipline the
Go node agent's internal/tools registry follows for its own module code.
"""

from __future__ import annotations

import secrets
from dataclasses import dataclass
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent


class InvalidEnrollSecret(Exception):
    """Raised when the caller's enroll_secret doesn't match ours."""


@dataclass
class EnrollRequest:
    name: str
    enroll_secret: str
    token: str
    address: str | None = None


async def enroll_agent(session: AsyncSession, configured_secret: str, req: EnrollRequest) -> Agent:
    """Validates req.enroll_secret against configured_secret (constant-time
    compare — the only authentication possible before any per-agent trust
    exists yet) and upserts an Agent row by name: a first-time enrollment
    creates it as 'enrolled'; re-enrolling an already-known name (e.g. a
    reinstalled agent, or a token rotation) updates it in place rather
    than erroring — mirrors the Go Selecta's Manager.Enroll "re-enrolling
    under the same name refreshes it" semantics.
    """
    if not secrets.compare_digest(req.enroll_secret, configured_secret):
        raise InvalidEnrollSecret()

    agent = await session.scalar(select(Agent).where(Agent.name == req.name))
    now = datetime.now(timezone.utc)
    if agent is None:
        agent = Agent(
            name=req.name,
            address=req.address,
            token=req.token,
            enrollment_state="enrolled",
            enrolled_at=now,
        )
        session.add(agent)
    else:
        agent.address = req.address
        agent.token = req.token
        agent.enrollment_state = "enrolled"
        agent.enrolled_at = now
    await session.flush()
    return agent
