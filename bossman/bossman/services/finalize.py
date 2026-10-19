"""Finalizing a deployment: the runbook a new host runs once its agent first reports (image restore and network
install alike) — chosen in the deploy wizard or with deploy_vm(finalize_runbook=...).

`arm()` records it as `waiting`. `kick()` — called wherever deployments are looked at (the pxe container's
/netboot/config poll every few seconds, deployment_status) — starts every waiting finalization whose host has
reported since it was armed: the row is set `running` and committed BEFORE the runbook starts, so two polls can never
start it twice; the runbook then runs in the background with its own session and ends `done` or `failed` with the
result. `apply=false` runs it in check mode (a preview of what it would change).
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import select

from bossman.db.models import Agent, DeployFinalization, Runbook

log = logging.getLogger(__name__)

#: running tasks, so they are not garbage-collected mid-run
_TASKS: set[asyncio.Task] = set()


class FinalizeError(ValueError):
    pass


async def check_runbook(session, name: str) -> Runbook:
    """The stored runbook, or the reason it cannot finalize a host (missing, or a role rather than a runbook)."""
    from bossman.services import nt_runbook

    rb = await session.scalar(select(Runbook).where(Runbook.name == name))
    if rb is None:
        raise FinalizeError(f"no runbook {name!r} (list_runbooks shows the stored ones)")
    if not isinstance(nt_runbook.parse_data(rb.doc), nt_runbook.Runbook):
        raise FinalizeError(f"{name!r} is a role, not a runbook — bind roles instead")
    return rb


async def arm(session, agent: Agent, *, runbook: str, variables: dict[str, Any] | None, apply: bool,
              requested_by: str) -> DeployFinalization:
    await check_runbook(session, runbook)
    row = DeployFinalization(agent_id=agent.id, hostname=agent.name, runbook=runbook, variables=variables or {},
                             apply=apply, requested_by=requested_by)
    session.add(row)
    await session.commit()
    return row


async def kick(session, *, session_factory, settings, client_factory) -> list[str]:
    """Start every waiting finalization whose host has reported since it was armed. Returns the hostnames started."""
    started = []
    for row in (await session.scalars(select(DeployFinalization).where(DeployFinalization.status == "waiting"))).all():
        agent = await session.get(Agent, row.agent_id)
        if agent is None or agent.last_seen_at is None or agent.last_seen_at <= row.created_at:
            continue
        row.status, row.started_at = "running", datetime.now(timezone.utc)
        await session.commit()
        task = asyncio.create_task(_run(row.id, session_factory=session_factory, settings=settings,
                                        client_factory=client_factory))
        _TASKS.add(task)
        task.add_done_callback(_TASKS.discard)
        started.append(row.hostname)
    return started


async def _run(row_id, *, session_factory, settings, client_factory) -> None:
    from bossman.services import nt_runbook, runbook_exec

    async with session_factory() as session:
        row = await session.get(DeployFinalization, row_id)
        try:
            agent = await session.get(Agent, row.agent_id)
            rb = await check_runbook(session, row.runbook)
            doc = nt_runbook.parse_data(rb.doc)
            _run_row, rr = await runbook_exec.execute_runbook(
                session, agent, doc, settings=settings, client=client_factory(agent, settings),
                request_vars=row.variables or {}, dry_run=not row.apply, requested_by=row.requested_by, commit=True)
            row.result = _summary(rr)
            row.status = "done" if not row.result.get("failed") else "failed"
            if row.status == "failed":
                row.error = row.result.get("error") or "a step failed — see result.steps"
        except Exception as exc:  # noqa: BLE001 — the reason is stored, never swallowed
            log.warning("finalization %s on %s failed: %s", row.runbook, row.hostname, exc)
            row.status, row.error = "failed", str(exc)[:2000]
        row.finished_at = datetime.now(timezone.utc)
        await session.commit()


def _summary(rr: dict[str, Any]) -> dict[str, Any]:
    """nt_engine.RunResult.to_dict() reduced to what an operator reads: ok/changed/aborted and per step its status."""
    steps = [s for s in rr.get("steps") or [] if isinstance(s, dict)]
    failed = [s for s in steps if s.get("status") == "failed"]
    return {"ok": bool(rr.get("ok")), "changed": rr.get("changed"), "aborted": rr.get("aborted"),
            "check_mode": rr.get("check_mode"), "failed": bool(failed) or rr.get("ok") is False,
            "steps": [{k: s.get(k) for k in ("name", "module", "status", "changed", "error") if s.get(k) is not None}
                      for s in steps][:200],
            "error": (failed[0].get("error") or failed[0].get("name")) if failed else None}


async def status(session, hostname: str) -> dict[str, Any] | None:
    row = await session.scalar(select(DeployFinalization).where(DeployFinalization.hostname == hostname)
                               .order_by(DeployFinalization.created_at.desc()).limit(1))
    if row is None:
        return None
    return {"runbook": row.runbook, "apply": row.apply, "status": row.status, "error": row.error,
            "result": row.result, "armed_at": row.created_at.isoformat(),
            "started_at": row.started_at.isoformat() if row.started_at else None,
            "finished_at": row.finished_at.isoformat() if row.finished_at else None}
