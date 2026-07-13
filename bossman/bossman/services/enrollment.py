"""Enrollment business logic (see docs/plan.md's Bossman plan, section
B.3). Kept free of FastAPI imports — reachable from the REST API, a future
MCP facade, and tests without duplicating logic, the same discipline the
Go node agent's internal/tools registry follows for its own module code.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent


@dataclass
class EnrollRequest:
    name: str
    token: str
    address: str | None = None


async def enroll_agent(session: AsyncSession, req: EnrollRequest) -> Agent:
    """Upsert an Agent row by name. Enrollment is OPEN — there is no secret
    (the SSH-driven deploy path is the authenticated way to add a host; the
    manual register command is a convenience). A first-time enrollment creates
    the agent as 'enrolled'; re-enrolling an already-known name (a reinstalled
    agent, or a token rotation) updates it in place rather than erroring —
    mirrors the Go Selecta's Manager.Enroll "re-enrolling under the same name
    refreshes it" semantics.
    """
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
