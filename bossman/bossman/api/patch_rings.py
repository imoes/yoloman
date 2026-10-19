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
from bossman.db.session import get_session
from bossman.services import patch_ring

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
    try:
        plan = await patch_ring.plan_patch_ring(
            session, name=body.name, state=body.state, category_names=body.category_names,
            accept_list=body.accept_list, reject_list=body.reject_list, reboot=body.reboot,
            scope_type=body.scope_type, agent_id=body.agent_id, host_group_id=body.host_group_id, ou_id=body.ou_id,
            strategy=body.strategy, by_ou=body.by_ou, canary=body.canary, one_at_a_time=body.one_at_a_time,
            dry_run=body.dry_run, wait_seconds=body.wait_seconds, max_fail_pct=body.max_fail_pct,
            created_by=identity.name)
    except patch_ring.PatchRingError as exc:
        raise HTTPException(422, str(exc)) from exc
    return PatchRingOut(rollout=RolloutOut.of(plan.rollout), runbook_name=plan.runbook_name,
                        windows_hosts=plan.windows_hosts, skipped=plan.skipped)
