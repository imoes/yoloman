"""GET /api/v1/enroll/info — tells a logged-in operator whether
enrollment is configured and, if so, the exact `agentic-mcpd register`
command to run against this Bossman instance (see docs/plan.md's
Monitoring-Ergänzung, Block E1 enrollment UX — the concrete fix for "I
can't create a new run": with zero enrolled hosts, the run dialog's host
picker has nothing to show, and enrollment was CLI-only with no
discoverable command in the UI).

Deliberately a separate, ALWAYS-mounted router from api/enroll.py's own
POST /api/v1/enroll (which is only mounted when enroll_secret is
configured, see main.py) — so the Settings page gets a real, informative
"not configured yet" response instead of a bare 404 either way.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from bossman.api.auth import get_current_identity
from bossman.config import Settings, get_settings

router = APIRouter()


class EnrollInfoResponse(BaseModel):
    configured: bool
    enroll_url: str | None = None
    register_command: str | None = None
    # Block N-enroll: whether server-driven SSH deploy is configured (SSH
    # user + an agent .deb path). When true the Settings page shows the
    # "deploy a new host by IP/DNS" field.
    deploy_configured: bool = False


@router.get("/api/v1/enroll/info", response_model=EnrollInfoResponse)
async def enroll_info(
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> EnrollInfoResponse:
    deploy_configured = bool(settings.deploy_ssh_user and settings.agent_deb_path)

    # Enrollment is open (no secret) — always available. The manual one-liner
    # is a convenience; the authenticated path is the SSH deploy above.
    url = settings.public_url or "http://<this-bossman-host>:8000"
    # `--write=true` enrols the host with the master write gate open so server-management tools and role
    # convergence work immediately; pass `--write=false` to enrol a monitor-only (read-only) host.
    command = f"agentic-mcpd register --enroll-url {url} --name $(hostname) --write=true"
    return EnrollInfoResponse(
        configured=True,
        enroll_url=url,
        register_command=command,
        deploy_configured=deploy_configured,
    )
