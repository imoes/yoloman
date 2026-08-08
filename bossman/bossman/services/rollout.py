"""Staged rollout driver (gap #8): run a runbook across the fleet in ordered
waves with a health gate between them — canary → ring 1 → ring 2, stop on
trouble.

plan_waves() splits a set of hosts into canary/percentage rings. execute_rollout
runs each wave (the runbook against that wave's hosts), waits, checks the wave's
hosts for hard CRIT, and only advances when the failure fraction is within the
gate — otherwise it aborts, leaving the rest of the fleet untouched. Progress is
persisted per wave so the UI shows it live. Best-effort per host; a runbook
failure on a host counts toward the gate.
"""

from __future__ import annotations

import asyncio
import logging
import math
from datetime import datetime, timezone

from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from bossman.config import Settings
from bossman.db.models import Agent, OUNode, Rollout, Service
from bossman.services import nt_runbook
from bossman.services.runbook_exec import execute_runbook

logger = logging.getLogger(__name__)


def plan_waves(agent_ids: list[str], strategy: list) -> list[dict]:
    """Split agent_ids into ordered waves per `strategy`, a list of batch sizes:
    an int (that many hosts), a "N%" string (that fraction), or "rest"/"100%"
    (everything remaining). e.g. [1, "25%", "rest"] = canary, quarter, the rest.
    Names default to canary/ring N."""
    remaining = list(agent_ids)
    total = len(remaining)
    waves: list[dict] = []
    for i, step in enumerate(strategy):
        if not remaining:
            break
        if isinstance(step, str) and step.strip().endswith("%"):
            n = max(1, math.ceil(total * float(step.strip().rstrip("%")) / 100.0))
        elif isinstance(step, str) and step.strip() in ("rest", "all", "100%"):
            n = len(remaining)
        else:
            n = int(step)
        n = min(n, len(remaining))
        name = "canary" if i == 0 and n == 1 else (f"ring {i}" if i else "wave 0")
        waves.append({"name": name, "agent_ids": remaining[:n]})
        remaining = remaining[n:]
    if remaining:  # anything left over becomes a final wave
        waves.append({"name": f"ring {len(waves)}", "agent_ids": remaining})
    return waves


async def plan_waves_by_ou(session: AsyncSession, ou_id, canary: bool = True) -> list[dict]:
    """AD-consistent waves: one wave PER OU in the target subtree, ordered
    shallow→deep (the parent OU rolls out and must pass the health gate before
    its children), each wave named by the OU path and carrying the hosts placed
    directly in that OU. This makes the rollout follow the same OU tree operators
    manage in Host placement, instead of arbitrary percentage slices of a flat
    host list. With `canary`, the first host of the first non-empty OU is pulled
    into its own leading wave. Hosts not placed in the subtree are not included."""
    target = await session.get(OUNode, ou_id)
    if target is None:
        return []
    ous = (
        await session.scalars(
            select(OUNode)
            .where(OUNode.tenant_id == target.tenant_id, text("ou_nodes.ltree_path <@ :p ::ltree"))
            .params(p=str(target.ltree_path))
        )
    ).all()
    # Shallow→deep (fewer ltree labels = shallower), then by human path for stability.
    ous_sorted = sorted(ous, key=lambda n: (str(n.ltree_path).count("."), n.path))
    ou_ids = [o.id for o in ous_sorted]
    agents = (
        await session.scalars(
            select(Agent).where(
                Agent.tenant_id == target.tenant_id, Agent.ou_id.in_(ou_ids), Agent.address.isnot(None)
            )
        )
    ).all()
    by_ou: dict = {}
    for a in agents:
        by_ou.setdefault(a.ou_id, []).append(str(a.id))

    waves: list[dict] = [
        {"name": o.path, "agent_ids": by_ou[o.id]} for o in ous_sorted if by_ou.get(o.id)
    ]
    if canary and waves and waves[0]["agent_ids"]:
        first = waves[0]
        head, tail = first["agent_ids"][0], first["agent_ids"][1:]
        rebuilt = [{"name": f"canary ({first['name']})", "agent_ids": [head]}]
        if tail:
            first["agent_ids"] = tail
            rebuilt.append(first)
        waves = rebuilt + waves[1:]
    return waves


async def _run_wave(session: AsyncSession, settings: Settings, rollout: Rollout, wave: dict, client_factory) -> dict:
    """Run the rollout's runbook against one wave's hosts. Returns a result
    dict {name, ok, failed, hosts:[{name,status}]}."""
    from bossman.db.models import Runbook

    rb = await session.scalar(select(Runbook).where(Runbook.name == rollout.runbook_name))
    doc = nt_runbook.parse_data(rb.doc, source=f"runbook {rollout.runbook_name!r}") if rb else None
    res = {"name": wave["name"], "ok": 0, "failed": 0, "hosts": []}
    if not isinstance(doc, nt_runbook.Runbook):
        res["failed"] = len(wave["agent_ids"])
        res["error"] = "runbook missing or is a role"
        return res
    for aid in wave["agent_ids"]:
        agent = await session.get(Agent, aid)
        if agent is None or not agent.address:
            continue
        try:
            _, rr = await execute_runbook(
                session, agent, doc, settings=settings, client=client_factory(agent, settings),
                request_vars=dict(rollout.variables or {}), dry_run=rollout.dry_run,
                requested_by=f"rollout:{rollout.name}", commit=False,
            )
            ok = rr.get("ok", True) and not rr.get("aborted")
            res["ok" if ok else "failed"] += 1
            res["hosts"].append({"name": agent.name, "status": "ok" if ok else "failed"})
        except Exception as exc:  # noqa: BLE001
            res["failed"] += 1
            res["hosts"].append({"name": agent.name, "status": f"error: {str(exc)[:80]}"})
    await session.commit()
    return res


async def _crit_hosts(session: AsyncSession, ids: list[str]) -> set[str]:
    """Wave hosts that currently have an unacked hard CRIT service."""
    rows = (await session.scalars(
        select(Service.agent_id).where(
            Service.agent_id.in_(ids), Service.state == "CRIT", Service.state_type == "hard",
            Service.acknowledged.is_(False),
        )
    )).all()
    return {str(a) for a in rows}


async def _wave_healthy(session: AsyncSession, wave: dict, baseline: set[str], max_fail_pct: float) -> tuple[bool, str]:
    """After a wave, is it healthy enough to proceed? Counts only hosts that
    went hard-CRIT DURING the wave (not in the pre-wave baseline) — a
    pre-existing, unrelated CRIT shouldn't block the rollout. Healthy if the new
    -failure fraction is within max_fail_pct."""
    ids = wave["agent_ids"]
    if not ids:
        return True, "no hosts"
    now_crit = await _crit_hosts(session, ids)
    new_crit = now_crit - baseline
    frac = len(new_crit) / len(ids)
    ok = frac <= max_fail_pct
    return ok, f"{len(new_crit)}/{len(ids)} newly CRIT ({frac*100:.0f}% vs gate {max_fail_pct*100:.0f}%)"


async def execute_rollout(
    session_factory: async_sessionmaker[AsyncSession], settings: Settings, rollout_id, client_factory=None,
) -> None:
    """Drive a rollout wave by wave with a health gate. Runs as a background
    task; persists status/progress as it goes. Aborts (leaving later waves
    untouched) the moment a wave breaches the health gate."""
    if client_factory is None:
        from bossman.services.agent_client import client_for
        client_factory = client_for
    gate_wait = 0
    max_fail = 0.0
    async with session_factory() as session:
        rollout = await session.get(Rollout, rollout_id)
        if rollout is None or rollout.status == "running":
            if rollout and rollout.status == "running":
                pass  # allow (re)start
        if rollout is None:
            return
        rollout.status = "running"
        rollout.started_at = datetime.now(timezone.utc)
        rollout.progress = []
        rollout.current_wave = 0
        waves = list(rollout.waves or [])
        gate = rollout.health_gate or {}
        gate_wait = int(gate.get("wait_seconds", 30))
        max_fail = float(gate.get("max_fail_pct", 0.0))
        await session.commit()

    aborted = False
    for i, wave in enumerate(waves):
        async with session_factory() as session:
            rollout = await session.get(Rollout, rollout_id)
            if rollout is None or rollout.status in ("aborted", "paused"):
                return
            rollout.current_wave = i
            await session.commit()
            # Snapshot pre-wave CRIT hosts so the gate only reacts to NEW damage.
            baseline = await _crit_hosts(session, wave["agent_ids"])
            result = await _run_wave(session, settings, rollout, wave, client_factory)

        # Let state settle (reboot, checks re-run), then gate.
        await asyncio.sleep(gate_wait)
        async with session_factory() as session:
            healthy, detail = await _wave_healthy(session, wave, baseline, max_fail)
            result["health"] = detail
            result["healthy"] = healthy
            rollout = await session.get(Rollout, rollout_id)
            rollout.progress = list(rollout.progress or []) + [result]
            if not healthy:
                rollout.status = "aborted"
                rollout.finished_at = datetime.now(timezone.utc)
                aborted = True
            await session.commit()
        if aborted:
            logger.warning("rollout %s aborted at wave %s: %s", rollout_id, i, result.get("health"))
            return

    async with session_factory() as session:
        rollout = await session.get(Rollout, rollout_id)
        if rollout and rollout.status == "running":
            rollout.status = "done"
            rollout.finished_at = datetime.now(timezone.utc)
            await session.commit()
