"""Agent-facing endpoints (Block L4): the reverse direction from the rest
of Bossman — a node agent calls INTO Bossman to pull its compiled desired
state and to acknowledge it. See docs/policy-orchestration-architecture.md §6.

Auth: the agent presents its own bearer token (the one it generated at
enrollment and Bossman stored as Agent.token) — Bossman verifies it by
looking the agent up by that token. This is a distinct path from the human
JWT / machine api-token used everywhere else (get_current_identity); here
the caller IS a specific enrolled agent, resolved to its Agent row.

Read-only with respect to real hosts: pulling a desired state and acking it
never mutates the host — it only records delivery/ack state. The agent-side
apply (Go) is a separate, later block.
"""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, AgentAck, AgentConfigDelivery
from bossman.db.session import get_session
from bossman.services.compiler import compile_host_desired_state

router = APIRouter()


async def get_current_agent(request: Request, session: AsyncSession = Depends(get_session)) -> Agent:
    """Resolve the calling agent from its bearer token (Agent.token). Only an
    enrolled agent is accepted."""
    auth_header = request.headers.get("authorization", "")
    if not auth_header.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = auth_header[len("bearer ") :]
    agent = await session.scalar(select(Agent).where(Agent.token == token))
    if agent is None or agent.enrollment_state != "enrolled":
        raise HTTPException(status_code=401, detail="invalid agent token")
    return agent


class DesiredStateResponse(BaseModel):
    agent_id: str
    generation: int
    config_hash: str
    state: dict


@router.get("/api/agent/v1/desired-state")
async def get_agent_desired_state(
    response: Response,
    current_hash: str | None = Query(None),
    agent: Agent = Depends(get_current_agent),
    session: AsyncSession = Depends(get_session),
):
    """The agent pulls its compiled desired state. Recompiles on demand (so a
    just-changed policy is reflected even before the reconciler runs), then:
    if the agent's current_hash already matches, returns 304 (nothing to do);
    otherwise returns the state and records the delivery as 'sent'."""
    result = await compile_host_desired_state(session, agent.id)
    if result is None:
        raise HTTPException(status_code=404, detail="no compiled state for this agent")
    await session.commit()

    if current_hash is not None and current_hash == result.config_hash:
        response.status_code = 304
        return Response(status_code=304)

    # Record/refresh the delivery for this generation (idempotent on the
    # (agent, generation) unique constraint) and mark it sent.
    delivery = await session.scalar(
        select(AgentConfigDelivery).where(
            AgentConfigDelivery.agent_id == agent.id, AgentConfigDelivery.generation == result.generation
        )
    )
    if delivery is None:
        delivery = AgentConfigDelivery(
            tenant_id=agent.tenant_id, agent_id=agent.id, generation=result.generation,
            config_hash=result.config_hash, status="sent",
        )
        session.add(delivery)
    else:
        delivery.status = "sent"
        delivery.updated_at = datetime.now(timezone.utc)
    agent.last_seen_at = datetime.now(timezone.utc)
    await session.commit()

    return DesiredStateResponse(
        agent_id=str(agent.id), generation=result.generation, config_hash=result.config_hash, state=result.state
    )


class AckRequest(BaseModel):
    generation: int
    result: str  # ack | nack
    detail: dict = {}


@router.post("/api/agent/v1/ack")
async def ack_desired_state(
    body: AckRequest,
    agent: Agent = Depends(get_current_agent),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """The agent acks/nacks a delivered generation — records an AgentAck and
    flips the matching delivery's status to acked/nacked."""
    if body.result not in ("ack", "nack"):
        raise HTTPException(status_code=422, detail="result must be 'ack' or 'nack'")
    session.add(
        AgentAck(tenant_id=agent.tenant_id, agent_id=agent.id, generation=body.generation, result=body.result, detail=body.detail)
    )
    delivery = await session.scalar(
        select(AgentConfigDelivery).where(
            AgentConfigDelivery.agent_id == agent.id, AgentConfigDelivery.generation == body.generation
        )
    )
    if delivery is not None:
        delivery.status = "acked" if body.result == "ack" else "nacked"
        delivery.updated_at = datetime.now(timezone.utc)
        if body.result == "nack":
            delivery.last_error = str(body.detail)[:2000]
    await session.commit()
    return {"status": "recorded", "result": body.result, "generation": body.generation}
