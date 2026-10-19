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

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import DEFAULT_TENANT_ID, Agent, Runbook

FOLDER = "windows/patch"
DEFAULT_CATEGORIES = ["CriticalUpdates", "SecurityUpdates", "UpdateRollups"]


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
