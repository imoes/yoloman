"""Patch rings — install Windows updates across the fleet in ordered waves with a health gate (plan B13).

A patch ring is NOT a new mechanism: it is an ordinary staged Rollout (services/rollout.py, gap #8) whose per-wave
action is the `windows_update` module instead of an arbitrary runbook. So the whole rollout machinery carries over —
canary → ring 1 → ring 2, the health gate between rings, pause/abort, dry-run, the UI — and a KB never lands on the
whole fleet at once.

This module only does the two things that are specific to patching:
  1. build (once, reused by signature) a runbook with a single `windows_update` step for the chosen KBs/categories, and
  2. keep a patch ring to WINDOWS hosts — a non-Windows host in the scope is dropped with its reason, never silently.

Nothing here runs anything; the caller creates the Rollout and starts it like any other (POST /rollouts/{id}/start).
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import DEFAULT_TENANT_ID, Agent, Rollout, Runbook

FOLDER = "windows/patch"
DEFAULT_CATEGORIES = ["CriticalUpdates", "SecurityUpdates", "UpdateRollups"]


class PatchRingError(ValueError):
    """A patch ring could not be planned, with a reason (the API maps it to 422, MCP to a tool error)."""


@dataclass
class PatchRingPlan:
    rollout: Rollout
    runbook_name: str
    windows_hosts: int
    skipped: list[dict]


async def plan_patch_ring(
    session: AsyncSession, *, name: str, state: str = "installed", category_names: list[str] | None = None,
    accept_list: list[str] | None = None, reject_list: list[str] | None = None, reboot: str = "never",
    scope_type: str, agent_id: UUID | None = None, host_group_id: UUID | None = None, ou_id: UUID | None = None,
    strategy: list | None = None, by_ou: bool = False, canary: bool = True, one_at_a_time: bool = False,
    dry_run: bool = True, wait_seconds: int = 300, max_fail_pct: float = 0.0, created_by: str = "",
) -> PatchRingPlan:
    """Plan a Windows patch ring as a staged Rollout and persist it (status pending — nothing installs until it is
    started). ONE orchestration shared by the REST route and the MCP tool, so both expose the same knobs. Raises
    PatchRingError for every bad input / empty scope, so no partial ring is created."""
    # Imported here to avoid a circular import (compiler/rollout import diagnosis/models that import this on some paths).
    from bossman.services.compiler import affected_agent_ids
    from bossman.services.rollout import plan_waves, plan_waves_by_ou

    if state not in ("searched", "downloaded", "installed"):
        raise PatchRingError("state must be searched|downloaded|installed")
    if reboot not in ("never", "if_required"):
        raise PatchRingError("reboot must be never|if_required")
    if scope_type not in ("host", "group", "ou", "global"):
        raise PatchRingError("scope_type must be host|group|ou|global")
    strategy = strategy or [1, "25%", "rest"]

    planned = None
    if by_ou:
        if scope_type != "ou" or ou_id is None:
            raise PatchRingError("by_ou requires scope_type=ou and ou_id")
        planned = await plan_waves_by_ou(session, ou_id, canary=canary)
        candidates = [aid for w in planned for aid in w["agent_ids"]]
    else:
        candidates = [str(a) for a in await affected_agent_ids(
            session, scope_type, ou_id=ou_id, agent_id=agent_id, host_group_id=host_group_id,
            tenant_id=DEFAULT_TENANT_ID)]
    if not candidates:
        raise PatchRingError("scope matched no hosts")

    windows, skipped = await windows_only(session, candidates)
    if not windows:
        raise PatchRingError("scope matched no Windows hosts; patch rings install Windows updates "
                             f"({len(skipped)} non-Windows host(s) skipped)")

    # Re-plan over the Windows hosts only, so a ring's slices are not thinned by hosts that were dropped.
    if by_ou:
        waves = [{"name": w["name"], "agent_ids": [a for a in w["agent_ids"] if a in set(windows)]} for w in planned]
        waves = [w for w in waves if w["agent_ids"]]
    else:
        waves = plan_waves(windows, strategy)
    if one_at_a_time:
        waves = [{"name": f"{w['name']} · {aid[:8]}", "agent_ids": [aid]} for w in waves for aid in w["agent_ids"]] or waves

    runbook_name = await ensure_patch_runbook(
        session, state=state, categories=category_names or [], accept=accept_list or [],
        reject=reject_list or [], reboot=reboot)

    r = Rollout(
        tenant_id=DEFAULT_TENANT_ID, name=name, runbook_name=runbook_name, test_runbook_name=None,
        variables={}, dry_run=dry_run, waves=waves,
        health_gate={"wait_seconds": wait_seconds, "max_fail_pct": max_fail_pct},
        status="pending", created_by=created_by,
    )
    session.add(r)
    await session.commit()
    await session.refresh(r)
    return PatchRingPlan(rollout=r, runbook_name=runbook_name, windows_hosts=len(windows), skipped=skipped)


def _args(state: str, categories: list[str], accept: list[str], reject: list[str], reboot: str) -> dict:
    args: dict = {"state": state, "category_names": categories or DEFAULT_CATEGORIES, "reboot": reboot}
    if accept:
        args["accept_list"] = accept
    if reject:
        args["reject_list"] = reject
    return args


def _signature(args: dict) -> str:
    import json
    return hashlib.sha256(json.dumps(args, sort_keys=True).encode()).hexdigest()[:10]


def describe(accept: list[str], categories: list[str]) -> str:
    """A short human label for the ring: the chosen KBs, else the categories, else "default security set"."""
    if accept:
        return ", ".join(accept)
    if categories:
        return ", ".join(categories)
    return "default security set"


async def ensure_patch_runbook(session: AsyncSession, *, state: str = "installed", categories: list[str] | None = None,
                               accept: list[str] | None = None, reject: list[str] | None = None,
                               reboot: str = "never") -> str:
    """The runbook for this exact patch set — one `windows_update` step, created once and reused by signature.

    reboot=never on purpose as the default: a wave that reboots per host would drop the agent mid-step; the operator
    reboots between rings, or passes reboot=if_required deliberately. No `when` guard: the ring is already restricted
    to Windows hosts at creation, and a mis-evaluated guard would skip the install silently — worse than none; the
    module itself refuses on a non-Windows host with a clear error."""
    args = _args(state, categories or [], accept or [], reject or [], reboot)
    name = f"Windows patch ring · {describe(accept or [], categories or [])} [{_signature(args)}]"
    doc = {
        "kind": "runbook", "name": name, "targets": None,
        "steps": [{
            "name": f"Install Windows updates ({state})",
            "module": "windows_update", "args": args,
        }],
    }
    existing = await session.scalar(select(Runbook).where(Runbook.name == name, Runbook.tenant_id == DEFAULT_TENANT_ID))
    if existing is None:
        session.add(Runbook(tenant_id=DEFAULT_TENANT_ID, name=name, kind="runbook", folder=FOLDER, doc=doc,
                            created_by="patch-ring"))
    else:
        existing.doc = doc   # keep it current if the module's arg shape changed
    await session.commit()
    return name


async def windows_only(session: AsyncSession, agent_ids: list) -> tuple[list[str], list[dict]]:
    """Split a candidate set into Windows hosts (kept) and the rest (dropped, each with its reason)."""
    kept: list[str] = []
    dropped: list[dict] = []
    for aid in agent_ids:
        agent = await session.get(Agent, aid)
        if agent is None:
            dropped.append({"agent_id": str(aid), "reason": "no such host"})
            continue
        family = str((agent.facts or {}).get("os_family") or "").lower()
        if family == "windows":
            kept.append(str(agent.id))
        else:
            dropped.append({"agent_id": str(agent.id), "host": agent.name,
                            "reason": f"not a Windows host (os_family={family or 'unknown'}) — windows_update does not apply"})
    return kept, dropped
