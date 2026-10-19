"""Tuning experiments — does a kernel tunable make a workload better, by measurement (docs/kernel-tuning.md, block 5).

One experiment measures one tunable candidate against the host as it is, with one fixed benchmark profile:

    A  B  A  B  A  B  …      (A = the host as it is, B = the candidate)

Alternating puts slow drift (a warming disk cache, a neighbour's load) on both sides instead of on one. The candidate
is set with the agent module `yoloman.<tunable>` and undone with the undo that same module reported, so the resource
history is not filled with flip-flops, and at the end the host is checked to be back at A.

The verdict is one of a closed set. WHETHER the sides differ is decided by a two-sided Mann-Whitney U test (exact;
robust to an outlier); whether the difference MATTERS by a minimum effect of MIN_EFFECT_PCT on the median:
    better | worse        p < ALPHA and the median moved by at least MIN_EFFECT_PCT
    no_difference         p < ALPHA but the move is below MIN_EFFECT_PCT (real, not worth it), or p ≥ ALPHA and the
                          move is below MIN_EFFECT_PCT (nothing worth having was seen)
    inconclusive          p ≥ ALPHA with a move of at least MIN_EFFECT_PCT (maybe real, not shown: run more), fewer
                          than MIN_RUNS runs a side, or runs scattering by more than MAX_NOISE_PCT (relative IQR)
    aborted               a run, the apply or the undo failed (the reason is stored)
Measured on Ubuntu 26.04 why it is these two questions and not one: a "ranges must not overlap" rule called a 9.4 %
gain no_difference because of one outlier; then "the move must exceed the runs' noise band (IQR)" called a 6.6 %
gain with p = 0.0015 (10+10 runs) no_difference — but the median's uncertainty shrinks with the number of runs,
the single run's scatter does not, so the band is the wrong yardstick for a difference of medians.

Block 6 (rehearsal): `snapshot=True` on a VM Bossman deployed takes a hypervisor snapshot first and rolls the VM
back to it at the end. That also allows tunables that need a reboot (kernel_cmdline): they cannot alternate, so they
run A×n, then the candidate plus a reboot, then B×n, and the summary says the runs were sequential.
"""
from __future__ import annotations

import asyncio
import logging
import statistics
import time
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import select

from bossman.db.models import Agent, TuningExperiment

log = logging.getLogger(__name__)

VERDICTS = ("better", "worse", "no_difference", "inconclusive", "aborted")
MIN_RUNS = 3
MAX_RUNS = 20
MIN_NOISE_PCT = 2.0
ALPHA = 0.05
MIN_EFFECT_PCT = 2.0
# Named into every summary, so a stored verdict says which rule produced it.
RULE = "rank-test+min-effect/2026-10-18"
MAX_NOISE_PCT = 25.0
# A running experiment that recorded nothing for this long was cut off (Bossman restarted mid-run).
STALE_AFTER = timedelta(minutes=30)

# experiment id → its running task, so "cut off" is decided per experiment, not by whether ANY experiment runs.
_RUNNING: dict[str, asyncio.Task] = {}


class ExperimentError(ValueError):
    def __init__(self, message: str, status: int = 422):
        super().__init__(message)
        self.status = status


def mann_whitney_p(a: list[float], b: list[float]) -> float:
    """Two-sided p of the Mann-Whitney U test, exact (no normal approximation — the samples are 3–20 a side).
    A tie counts half; the exact null distribution assumes none, which makes p slightly conservative with ties."""
    from functools import lru_cache

    n1, n2 = len(a), len(b)
    u = sum(1.0 if x > y else 0.5 if x == y else 0.0 for x in a for y in b)

    @lru_cache(maxsize=None)
    def ways(i: int, j: int, k: int) -> int:   # arrangements of i a's and j b's with exactly k (a > b) pairs
        if k < 0:
            return 0
        if i == 0 or j == 0:
            return 1 if k == 0 else 0
        return ways(i - 1, j, k - j) + ways(i, j - 1, k)

    total = sum(ways(n1, n2, k) for k in range(n1 * n2 + 1))
    lo = min(u, n1 * n2 - u)
    tail = sum(ways(n1, n2, k) for k in range(int(lo) + 1)) / total
    return min(1.0, 2 * tail)


def judge(a: list[float], b: list[float], *, higher_is_better: bool) -> dict[str, Any]:
    """The verdict for side A (as is) against side B (candidate), with every number it rests on."""
    out: dict[str, Any] = {"runs_a": len(a), "runs_b": len(b), "higher_is_better": higher_is_better}
    if len(a) < MIN_RUNS or len(b) < MIN_RUNS:
        return {**out, "verdict": "inconclusive",
                "reason": f"{len(a)} and {len(b)} valid runs; a verdict needs at least {MIN_RUNS} a side"}

    def iqr(xs: list[float]) -> float:
        q = statistics.quantiles(xs, n=4, method="inclusive")
        return q[2] - q[0]

    med_a, med_b = statistics.median(a), statistics.median(b)
    if med_a == 0:
        return {**out, "verdict": "inconclusive", "reason": "the baseline median is 0; no relative change can be computed"}
    noise = max(iqr(a) / abs(med_a), iqr(b) / abs(med_b) if med_b else 0.0) * 100
    noise = max(noise, MIN_NOISE_PCT)
    delta = (med_b - med_a) / abs(med_a) * 100
    gain = delta if higher_is_better else -delta
    overlap = not (max(b) < min(a) or max(a) < min(b))
    p = mann_whitney_p(a, b)
    out.update({"median_a": med_a, "median_b": med_b, "min_a": min(a), "max_a": max(a), "min_b": min(b),
                "max_b": max(b), "iqr_a": iqr(a), "iqr_b": iqr(b), "noise_pct": round(noise, 2),
                "delta_pct": round(delta, 2), "gain_pct": round(gain, 2), "ranges_overlap": overlap,
                "p_value": round(p, 4), "alpha": ALPHA, "min_effect_pct": MIN_EFFECT_PCT,
                "test": "Mann-Whitney U, two-sided, exact"})
    if noise > MAX_NOISE_PCT:
        return {**out, "verdict": "inconclusive",
                "reason": f"the runs scatter by {noise:.1f} % (IQR), more than the {MAX_NOISE_PCT:.0f} % a comparison can "
                          "rest on — quieten the host or raise the run count"}
    move = f"median {med_a:g} → {med_b:g} ({delta:+.1f} %)"
    if abs(delta) < MIN_EFFECT_PCT:
        return {**out, "verdict": "no_difference",
                "reason": f"{move} is below the {MIN_EFFECT_PCT:g} % worth acting on"
                          + (f" (real: p = {p:.3f})" if p < ALPHA else f" and not significant (p = {p:.3f})")}
    if p >= ALPHA:
        return {**out, "verdict": "inconclusive",
                "reason": f"{move}, but with {len(a)}+{len(b)} runs not significant (p = {p:.3f} ≥ {ALPHA}); run more"}
    return {**out, "verdict": "better" if gain > 0 else "worse",
            "reason": f"{move}, significant (Mann-Whitney U p = {p:.3f}, {len(a)}+{len(b)} runs; runs scatter ±{noise:.1f} %)"}


def _as_dict(row: TuningExperiment) -> dict[str, Any]:
    return {"id": str(row.id), "host": row.hostname, "tunable": row.tunable, "candidate": row.candidate,
            "profile": row.profile, "runs": row.runs, "hypothesis": row.hypothesis, "status": row.status,
            "verdict": row.verdict, "summary": row.summary, "measurements": row.measurements, "undo": row.undo,
            "rehearsal": row.rehearsal, "error": row.error, "requested_by": row.requested_by,
            "created_at": row.created_at.isoformat() if row.created_at else None,
            "started_at": row.started_at.isoformat() if row.started_at else None,
            "finished_at": row.finished_at.isoformat() if row.finished_at else None}


async def start(session, *, agent: Agent, tunable: str, params: dict[str, Any], profile: str, runs: int,
                hypothesis: str, requested_by: str, session_factory, settings, client_factory,
                snapshot: bool = False) -> dict[str, Any]:
    """Check the candidate (a refused or reboot-needing one is refused here, before anything changes), record the
    experiment and run it in the background. Returns the row as experiment_status shows it."""
    from bossman.services.resources.tunable import TunableError, TunableResource

    if not MIN_RUNS <= int(runs) <= MAX_RUNS:
        raise ExperimentError(f"runs must be {MIN_RUNS}–{MAX_RUNS} per side")
    try:
        res = TunableResource(session, agent, client_factory, settings, tunable)
        mod_params = res._params({"params": params})
    except TunableError as exc:
        raise ExperimentError(str(exc)) from exc
    plan = await res._call(mod_params, dry_run=True)
    if not plan["ok"]:
        r = plan["refusal"]
        raise ExperimentError(f"the candidate is refused by the host ({r['kind']}): {r['reason']}", status=409)
    if not plan["changed"]:
        raise ExperimentError("the candidate is what the host already has — there is no B to compare with A", status=409)
    reboot = (plan["data"] or {}).get("persistence") == "pending_reboot"
    rehearsal = None
    if reboot and not snapshot:
        raise ExperimentError(f"{tunable} takes effect only after a reboot; run it as a rehearsal on a VM Bossman "
                              "deployed (snapshot=true), where it is measured A×n → reboot → B×n and rolled back", status=409)
    if snapshot:
        rehearsal = await _rehearsal_target(session, agent)
    row = TuningExperiment(agent_id=agent.id, hostname=agent.name, tunable=tunable, candidate=mod_params,
                           profile=profile, runs=int(runs), hypothesis=hypothesis or "", status="running",
                           requested_by=requested_by, started_at=datetime.now(timezone.utc),
                           rehearsal={**rehearsal, "sequential": reboot} if rehearsal else None)
    session.add(row)
    await session.commit()
    task = asyncio.create_task(_run(row.id, session_factory=session_factory, settings=settings,
                                    client_factory=client_factory))
    key = str(row.id)
    _RUNNING[key] = task
    task.add_done_callback(lambda _t, k=key: _RUNNING.pop(k, None))
    return _as_dict(row)


async def _rehearsal_target(session, agent: Agent) -> dict[str, Any]:
    """The VM a snapshot can be taken of: the newest install or restore job that created this host's VM."""
    from bossman.db.models import NetinstallJob, RestoreJob

    for model, name_col in ((NetinstallJob, NetinstallJob.hostname), (RestoreJob, RestoreJob.target_hostname)):
        job = await session.scalar(select(model).where(name_col == agent.name, model.vm_id.is_not(None))
                                   .order_by(model.created_at.desc()).limit(1))
        if job is not None and job.vm_host_id and job.vm_id:
            return {"vm_host_id": str(job.vm_host_id), "vm_node": job.vm_node, "vm_id": job.vm_id}
    raise ExperimentError(f"{agent.name} is not a VM Bossman deployed (no install or restore job names its VM), so "
                          "there is nothing to snapshot — run the experiment without snapshot", status=409)


async def _bench(client, profile: str) -> dict[str, Any]:
    res = await client.call_tool("yoloman.benchmark", {"profile": profile})
    data = (res or {}).get("data") or {}
    if "value" not in data:
        raise ExperimentError(f"the benchmark returned no value: {str(res)[:300]}")
    return data


async def _run(row_id, *, session_factory, settings, client_factory) -> None:
    from bossman.services import hypervisor
    from bossman.services.resources.tunable import TUNABLES
    from bossman.services import vm_provision as vp
    from bossman.db.models import VmHost

    async with session_factory() as session:
        row = await session.get(TuningExperiment, row_id)
        agent = await session.get(Agent, row.agent_id)
        client = client_factory(agent, settings)
        module = TUNABLES[row.tunable.split(":")[0]][0]
        meas: list[dict[str, Any]] = []
        undo: dict[str, Any] | None = None
        unit, higher = "", True
        snap = None
        hv = None

        async def record(side: str, run: int) -> None:
            nonlocal unit, higher
            data = await _bench(client, row.profile)
            unit, higher = data.get("unit", ""), bool(data.get("higher_is_better", True))
            meas.append({"side": side, "run": run, "value": float(data["value"]), "unit": unit,
                         "metric": data.get("metric"), "at": datetime.now(timezone.utc).isoformat()})
            row.measurements = list(meas)
            await session.commit()

        async def set_b() -> None:
            nonlocal undo
            res = await client.call_tool(module, {**row.candidate, "dry_run": False})
            rb = ((res or {}).get("data") or {}).get("rollback")
            if undo is None:
                if not rb:
                    raise ExperimentError(f"{module} reported no rollback; the experiment cannot return the host to A")
                undo = rb
                row.undo = rb
                await session.commit()

        async def set_a() -> None:
            await client.call_tool(module, {**undo, "dry_run": False})

        try:
            if row.rehearsal:
                vm_host = await session.get(VmHost, uuid.UUID(row.rehearsal["vm_host_id"]))
                hv = vp.client_for(vm_host)
                snap = f"yoloman-exp-{str(row.id)[:8]}"
                await hv.vm_snapshot(row.rehearsal["vm_id"], snap, row.rehearsal.get("vm_node"))
                row.rehearsal = {**row.rehearsal, "snapshot": snap}
                await session.commit()
            if (row.rehearsal or {}).get("sequential"):
                for i in range(1, row.runs + 1):
                    await record("A", i)
                await set_b()
                await _reboot_and_wait(client, agent, session)
                for i in range(1, row.runs + 1):
                    await record("B", i)
            else:
                for i in range(1, row.runs + 1):
                    await record("A", i)
                    await set_b()
                    await record("B", i)
                    await set_a()
            a = [m["value"] for m in meas if m["side"] == "A"]
            b = [m["value"] for m in meas if m["side"] == "B"]
            summary = judge(a, b, higher_is_better=higher)
            summary["unit"] = unit
            summary["rule"] = RULE
            summary["order"] = "sequential (A×n, reboot, B×n)" if (row.rehearsal or {}).get("sequential") else "alternating A/B"
            row.summary, row.verdict, row.status = summary, summary["verdict"], "done"
        except Exception as exc:  # noqa: BLE001 — the reason is stored, never swallowed
            log.warning("experiment %s on %s aborted: %s", row.id, row.hostname, exc)
            row.status, row.verdict, row.error = "aborted", "aborted", str(exc)[:2000]
            if undo is not None and not row.rehearsal:
                try:
                    await set_a()
                except Exception as exc2:  # noqa: BLE001
                    row.error += f" — and undoing the candidate failed too: {exc2}"[:1000]
        finally:
            if hv is not None and snap:
                try:
                    await hv.vm_snapshot_rollback(row.rehearsal["vm_id"], snap, row.rehearsal.get("vm_node"))
                    await hv.vm_power(row.rehearsal["vm_id"], "start", row.rehearsal.get("vm_node"))
                    await hv.vm_snapshot_delete(row.rehearsal["vm_id"], snap, row.rehearsal.get("vm_node"))
                    row.rehearsal = {**row.rehearsal, "rolled_back": True}
                except hypervisor.HypervisorError as exc:
                    row.rehearsal = {**row.rehearsal, "rolled_back": False, "rollback_error": str(exc)[:500]}
            elif undo is not None:
                # Back at A? Ask the module in check mode whether applying the undo would still change anything.
                try:
                    chk = await client.call_tool(module, {**undo, "dry_run": True})
                    restored = not bool((chk or {}).get("changed"))
                except Exception as exc:  # noqa: BLE001
                    restored = False
                    row.error = (row.error or "") + f" (could not verify the host is back at A: {exc})"
                row.summary = {**(row.summary or {}), "restored": restored}
            row.finished_at = datetime.now(timezone.utc)
            await session.commit()


async def _reboot_and_wait(client, agent: Agent, session, timeout_s: int = 600) -> None:
    """Reboot the host (the agent's reboot module) and wait until its agent reports again."""
    before = agent.last_seen_at
    await client.call_tool("reboot", {"dry_run": False})
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout_s:
        await asyncio.sleep(10)
        await session.refresh(agent)
        if agent.last_seen_at and (before is None or agent.last_seen_at > before + timedelta(seconds=20)):
            try:
                await client.call_tool("setup", {})
                return
            except Exception:  # noqa: BLE001 — still booting
                continue
    raise ExperimentError(f"{agent.name} did not come back within {timeout_s}s after the reboot")


async def status(session, experiment_id: str, *, wait_s: int = 0) -> dict[str, Any]:
    """The experiment as stored; wait_s (0–900) waits for it to finish or record a new run."""
    try:
        eid = uuid.UUID(str(experiment_id))
    except ValueError as exc:
        raise ExperimentError(f"not an experiment id: {experiment_id!r}") from exc
    t0 = time.monotonic()
    wait_s = max(0, min(int(wait_s or 0), 900))
    first = None
    while True:
        row = await session.get(TuningExperiment, eid, populate_existing=True)
        if row is None:
            raise ExperimentError(f"no experiment {experiment_id}", status=404)
        mark = (row.status, len(row.measurements or []))
        first = first or mark
        if row.status == "running" and str(row.id) not in _RUNNING and _stale(row):
            row.status, row.verdict = "aborted", "aborted"
            row.error = ("cut off: nothing was recorded for 30 minutes and no experiment task runs (Bossman restarted?)"
                         + (f" — the candidate may still be applied; undo: {row.undo}" if row.undo else ""))
            row.finished_at = datetime.now(timezone.utc)
            await session.commit()
        if not wait_s or row.status != "running" or mark != first or time.monotonic() - t0 >= wait_s:
            out = _as_dict(row)
            if wait_s:
                out["waited_s"] = round(time.monotonic() - t0)
            return out
        await asyncio.sleep(5)


def _stale(row: TuningExperiment) -> bool:
    last = row.started_at
    for m in row.measurements or []:
        try:
            last = max(last, datetime.fromisoformat(m["at"]))
        except (KeyError, ValueError, TypeError):
            pass
    return last is not None and datetime.now(timezone.utc) - last > STALE_AFTER


async def list_for(session, agent: Agent | None, limit: int = 20) -> list[dict[str, Any]]:
    q = select(TuningExperiment).order_by(TuningExperiment.created_at.desc()).limit(limit)
    if agent is not None:
        q = q.where(TuningExperiment.agent_id == agent.id)
    rows = (await session.scalars(q)).all()
    return [{k: v for k, v in _as_dict(r).items() if k != "measurements"} for r in rows]
