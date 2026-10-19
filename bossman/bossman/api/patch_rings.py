"""Patch-ring API (plan B13): install Windows updates across the fleet in ordered waves with a health gate.

A patch ring IS a staged rollout (see api/rollouts) whose per-wave action is the `windows_update` module. This
endpoint builds the windows_update runbook, restricts the scope to Windows hosts, plans the waves and creates the
Rollout — then it is driven, started, paused and aborted exactly like any other rollout (/api/v1/rollouts/...).
"""

from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity
from bossman.api.rollouts import RolloutOut
from bossman.db.models import DEFAULT_TENANT_ID, Rollout
from bossman.db.session import get_session
from bossman.services import patch_ring
from bossman.services.compiler import affected_agent_ids
from bossman.services.rollout import plan_waves, plan_waves_by_ou

router = APIRouter()


class PatchRingIn(BaseModel):
    name: str
    # what to install — same meaning as the windows_update module / ansible.windows.win_updates
    state: str = "installed"                 # searched | downloaded | installed
    category_names: list[str] = []           # empty → CriticalUpdates, SecurityUpdates, UpdateRollups
    accept_list: list[str] = []              # only these KBs/patterns
    reject_list: list[str] = []
    reboot: str = "never"                    # never | if_required
    # where — the same scope + wave model as a rollout
    scope_type: str                          # host | group | ou | global
    agent_id: UUID | None = None
    host_group_id: UUID | None = None
    ou_id: UUID | None = None
    strategy: list = [1, "25%", "rest"]
    by_ou: bool = False
    canary: bool = True
    one_at_a_time: bool = False
    dry_run: bool = True                     # default to a dry run: show what each ring would install, change nothing
    wait_seconds: int = 300                  # patches + reboot take longer than a config change
    max_fail_pct: float = 0.0


class PatchRingOut(BaseModel):
    rollout: RolloutOut
    runbook_name: str
    windows_hosts: int
    skipped: list[dict]


@router.post("/api/v1/patch-rings", response_model=PatchRingOut)
async def create_patch_ring(body: PatchRingIn, session: AsyncSession = Depends(get_session),
                            identity: Identity = Depends(get_current_identity)) -> PatchRingOut:
    """Plan a Windows patch ring. **Nothing installs until `/api/v1/rollouts/{id}/start`.**

    The scope is expanded now and frozen into waves (a host added to a group later is not pulled into a running ring).
    Only Windows hosts are kept; every other host in the scope is returned in `skipped` with its reason, never silently
    dropped. 422 when no Windows host matched."""
    if body.state not in ("searched", "downloaded", "installed"):
        raise HTTPException(422, "state must be searched|downloaded|installed")
    if body.reboot not in ("never", "if_required"):
        raise HTTPException(422, "reboot must be never|if_required")
    if body.scope_type not in ("host", "group", "ou", "global"):
        raise HTTPException(422, "scope_type must be host|group|ou|global")

    if body.by_ou:
        if body.scope_type != "ou" or body.ou_id is None:
            raise HTTPException(422, "by_ou requires scope_type=ou and ou_id")
        planned = await plan_waves_by_ou(session, body.ou_id, canary=body.canary)
        candidates = [aid for w in planned for aid in w["agent_ids"]]
    else:
        candidates = [str(a) for a in await affected_agent_ids(
            session, body.scope_type, ou_id=body.ou_id, agent_id=body.agent_id,
            host_group_id=body.host_group_id, tenant_id=DEFAULT_TENANT_ID)]
    if not candidates:
        raise HTTPException(422, "scope matched no hosts")

    windows, skipped = await patch_ring.windows_only(session, candidates)
    if not windows:
        raise HTTPException(422, "scope matched no Windows hosts; patch rings install Windows updates "
                                 f"({len(skipped)} non-Windows host(s) skipped)")

    # Re-plan the waves over the WINDOWS hosts only, so a ring's slices are not thinned by hosts that were dropped.
    if body.by_ou:
        waves = [{"name": w["name"], "agent_ids": [a for a in w["agent_ids"] if a in set(windows)]} for w in planned]
        waves = [w for w in waves if w["agent_ids"]]
    else:
        waves = plan_waves(windows, body.strategy)
    if body.one_at_a_time:
        waves = [{"name": f"{w['name']} · {aid[:8]}", "agent_ids": [aid]} for w in waves for aid in w["agent_ids"]] or waves

    runbook_name = await patch_ring.ensure_patch_runbook(
        session, state=body.state, categories=body.category_names, accept=body.accept_list,
        reject=body.reject_list, reboot=body.reboot)

    r = Rollout(
        tenant_id=DEFAULT_TENANT_ID, name=body.name, runbook_name=runbook_name, test_runbook_name=None,
        variables={}, dry_run=body.dry_run, waves=waves,
        health_gate={"wait_seconds": body.wait_seconds, "max_fail_pct": body.max_fail_pct},
        status="pending", created_by=identity.name,
    )
    session.add(r)
    await session.commit()
    await session.refresh(r)
    return PatchRingOut(rollout=RolloutOut.of(r), runbook_name=runbook_name, windows_hosts=len(windows), skipped=skipped)
