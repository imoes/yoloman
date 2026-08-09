"""POST /api/v1/enroll/deploy — server-driven SSH deploy of a new node
agent (Block N-enroll). The operator supplies just a host (IP/DNS); Bossman
SSHes in with its pre-configured operator identity, installs the agent .deb,
provisions a complete Bossman-managed config.yaml (token + TLS + pinned
key), and records the host as enrolled. See services/deploy.py for the
trust model (no enrollment secret — the SSH channel is the root of trust).

Always mounted (like enroll_info, unlike the secret-gated enroll router):
the endpoint reports its own "not configured" state via a 400 with a
helpful message rather than a bare 404.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings
from bossman.db.session import get_session
from bossman.services.deploy import DeployError, deploy_and_enroll

router = APIRouter()


class DeployRequestBody(BaseModel):
    host: str
    port: int | None = None
    write: bool | None = None


class DeployResponseBody(BaseModel):
    agent_id: str
    name: str
    address: str | None = None


@router.post("/api/v1/enroll/deploy", response_model=DeployResponseBody)
async def handle_deploy(
    body: DeployRequestBody,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> DeployResponseBody:
    try:
        agent = await deploy_and_enroll(
            session, settings, body.host, port=body.port, write=body.write
        )
    except DeployError as exc:
        # 400: every DeployError is either a misconfiguration or a
        # deploy-time failure the operator needs to read and act on.
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    await session.commit()
    return DeployResponseBody(agent_id=str(agent.id), name=agent.name, address=agent.address)
