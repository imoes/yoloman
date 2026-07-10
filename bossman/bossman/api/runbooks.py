"""Block G11 (NT format, step 7): the runbook REST surface — lint a NT
document, run a runbook against a host (dry-run/apply), and compile a role
into an OrchestrationPlan create-payload.

Runs the tested engine (services/nt_engine) over the agent client. `run` needs
manage rights on the host; a dry run (`dry_run: true`, the default) previews
every step in check_mode without touching the host — the same preview→confirm
posture as plan runs.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent
from bossman.db.session import get_session
from bossman.services import nt_compile, nt_engine, nt_runbook
from bossman.services.auth import Identity, user_can_manage_agent

router = APIRouter()


class NTBody(BaseModel):
    nt: str


@router.post("/api/v1/runbooks/lint")
async def lint_runbook(body: NTBody, _identity=Depends(get_current_identity)) -> dict[str, Any]:
    """Parse + shape-validate a NestedText runbook or role. Returns
    {ok, kind, name} or {ok: false, error}."""
    try:
        doc = nt_runbook.parse_document(body.nt)
    except nt_runbook.NTRunbookError as exc:
        return {"ok": False, "error": str(exc)}
    return {"ok": True, "kind": doc.kind, "name": doc.name, "steps": len(doc.steps)}


class RunBody(BaseModel):
    nt: str
    variables: dict[str, Any] = {}
    dry_run: bool = True


@router.post("/api/v1/agents/{agent_id}/runbook/run")
async def run_runbook(
    agent_id: UUID,
    body: RunBody,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity: Identity = Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Run a NestedText runbook against a host. dry_run (default true) previews
    every step in check_mode. Needs manage rights on the host."""
    if not await user_can_manage_agent(session, identity, agent_id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="no such agent")
    if not agent.address:
        raise HTTPException(status_code=422, detail="agent has no address to reach")
    try:
        doc = nt_runbook.parse_document(body.nt)
    except nt_runbook.NTRunbookError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    if not isinstance(doc, nt_runbook.Runbook):
        raise HTTPException(status_code=422, detail="that is a role, not a runbook — bind it in OU / Policy instead")

    client = client_factory(agent, settings)

    # Magic variables (Ansible-style): the agent's own facts — hostname,
    # distribution, and hardware/DMI (motherboard vendor, product, serial,
    # BIOS) via the read-only `setup` module — are made available to the
    # runbook as ${ansible_*} / ${inventory_hostname}. Explicit request
    # variables win over facts. Best-effort: if setup fails, the runbook still
    # runs with whatever variables were passed.
    magic: dict[str, Any] = {"inventory_hostname": agent.name}
    try:
        facts_resp = await client.call_tool("setup", {})
        if isinstance(facts_resp, dict):
            facts = facts_resp.get("data") if isinstance(facts_resp.get("data"), dict) else facts_resp
            if isinstance(facts, dict):
                magic.update(facts)
    except Exception:  # noqa: BLE001 — facts are best-effort, never block the run
        pass
    variables = {**magic, **(body.variables or {})}

    result = await nt_engine.run_runbook(doc, client, variables, check_mode=body.dry_run)
    return {"agent_id": str(agent_id), "runbook": doc.name, "facts_gathered": len(magic) - 1, **result.to_dict()}


@router.post("/api/v1/runbooks/role/compile")
async def compile_role(body: NTBody, _identity=Depends(get_current_identity)) -> dict[str, Any]:
    """Compile a NestedText role into an OrchestrationPlan create-payload
    (name/display_name/plan_type/version with steps + generated_monitoring +
    notifications) — POST it to /api/v1/orchestration/plans to store it."""
    try:
        doc = nt_runbook.parse_document(body.nt)
    except nt_runbook.NTRunbookError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    if not isinstance(doc, nt_runbook.Role):
        raise HTTPException(status_code=422, detail="that is a runbook, not a role (needs a top-level `role:`)")
    return {"plan_input": nt_compile.role_to_plan_input(doc)}
