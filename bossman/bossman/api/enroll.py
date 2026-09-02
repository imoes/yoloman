"""POST /api/v1/enroll — Bossman's server side of the enrollment
handshake the Go client (`agentic-mcpd register`, package internal/enroll)
speaks. Enrollment is OPEN: there is no secret — the agent hands over its
name/token/address and receives Bossman's public key (which it pins so
Bossman can authenticate itself with its private key over TLS client certs
from then on). The authenticated way to add a host is the server-driven SSH
deploy (api/deploy.py); this endpoint is the manual convenience. Always
mounted (see bossman/main.py). An optional `enroll_secret` in the body is
accepted for wire-compatibility with the generic client but ignored.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services import keys
from bossman.services.enrollment import EnrollRequest, enroll_agent

router = APIRouter()


class EnrollRequestBody(BaseModel):
    name: str
    token: str
    address: str | None = None
    # Accepted for wire-compatibility with the generic register client, but
    # ignored — Bossman enrollment is open.
    enroll_secret: str | None = None


class EnrollResponseBody(BaseModel):
    bossman_public_key: str
    agent_id: str


@router.post("/api/v1/enroll", response_model=EnrollResponseBody)
async def handle_enroll(
    body: EnrollRequestBody,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> EnrollResponseBody:
    """An agent registers itself. **Enrolment is OPEN: there is no shared secret.**

    The agent sends its name, token and address and receives Bossman's public key, which it **pins**
    — from then on Bossman authenticates itself with the matching private key over mTLS. An
    `enroll_secret` in the body is accepted for wire-compatibility with the generic client and
    **ignored**.

    So the trust model is plainly: whoever can reach this endpoint can add a host, and it is mounted
    unconditionally. The authenticated way to add one is the server-driven SSH deploy
    (`POST /api/v1/enroll/deploy`), where Bossman dials out; this is the manual convenience, and the
    reason this path is worth firewalling.

    Note the direction of every later call: the agent never dials in again — Bossman connects to the
    agent, which is why one firewall rule (Bossman → agent) is enough.
    """
    if not body.name:
        raise HTTPException(status_code=400, detail="name must not be empty")
    if not body.token:
        raise HTTPException(status_code=400, detail="token is required")

    agent = await enroll_agent(
        session,
        EnrollRequest(name=body.name, token=body.token, address=body.address),
    )
    await session.commit()

    keys.ensure_client_keypair(settings.client_key_path, settings.client_cert_path)
    public_key_pem = keys.own_public_key_pem(settings.client_cert_path)

    return EnrollResponseBody(bossman_public_key=public_key_pem.decode(), agent_id=str(agent.id))
