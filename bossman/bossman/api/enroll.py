"""POST /api/v1/enroll — Bossman's server side of the enrollment
handshake the Go client (`agentic-mcpd register`, package internal/enroll)
already speaks (see docs/plan.md's Bossman plan, section B.3, and the
"Enrollment" / "Selecta" sections earlier in that file for the identical
protocol already implemented on a Selecta). Only mounted when
BOSSMAN_ENROLL_SECRET is actually configured (see bossman/main.py) — an
unconfigured Bossman shouldn't accept enrollments at all, mirroring the Go
Selecta's identical gating on a non-empty proxy.enroll_secret.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services import keys
from bossman.services.enrollment import EnrollRequest, InvalidEnrollSecret, enroll_agent

router = APIRouter()


class EnrollRequestBody(BaseModel):
    name: str
    enroll_secret: str
    token: str
    address: str | None = None


class EnrollResponseBody(BaseModel):
    bossman_public_key: str
    agent_id: str


@router.post("/api/v1/enroll", response_model=EnrollResponseBody)
async def handle_enroll(
    body: EnrollRequestBody,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
) -> EnrollResponseBody:
    if not body.name:
        raise HTTPException(status_code=400, detail="name must not be empty")
    if not body.token:
        raise HTTPException(status_code=400, detail="token is required")

    try:
        agent = await enroll_agent(
            session,
            settings.enroll_secret,
            EnrollRequest(name=body.name, enroll_secret=body.enroll_secret, token=body.token, address=body.address),
        )
    except InvalidEnrollSecret:
        raise HTTPException(status_code=401, detail="invalid enroll_secret") from None
    await session.commit()

    keys.ensure_client_keypair(settings.client_key_path, settings.client_cert_path)
    public_key_pem = keys.own_public_key_pem(settings.client_cert_path)

    return EnrollResponseBody(bossman_public_key=public_key_pem.decode(), agent_id=str(agent.id))
