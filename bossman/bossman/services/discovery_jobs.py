"""In-memory registry of running discovery jobs, so the UI can show a percent bar.

Discovery probes ~1400 checks against a host and takes seconds. The HTTP request that starts it returns
a job id immediately; the browser then polls this registry for `completed`/`total` and renders a bar.

Deliberately in-memory (on app.state), NOT the database: a discovery job is ephemeral progress, not
durable state — if the process restarts mid-run the browser's poll 404s and it simply re-runs discovery.
Writing per-check progress to Postgres would be far more churn than the thing is worth. This assumes a
single Bossman process (the deployment runs one uvicorn); with multiple workers a poll could hit a
worker that never saw the job, which is the one caveat of not using shared storage.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Any

# Keep at most this many finished jobs around, so a long-lived process does not accumulate them. The
# browser polls a job only until it reads `done`, so a small ring is plenty.
_MAX_JOBS = 64


@dataclass
class DiscoveryJob:
    id: str
    total: int
    completed: int = 0
    done: bool = False
    error: str | None = None
    result: dict[str, Any] | None = None

    def snapshot(self) -> dict[str, Any]:
        # percent is derived, clamped, and integer — the UI shows it directly. 100% only once `done`,
        # so the bar never sits at 100 while the reconcile/commit tail is still running.
        pct = 0
        if self.total > 0:
            pct = min(99, int(100 * self.completed / self.total))
        if self.done and self.error is None:
            pct = 100
        out: dict[str, Any] = {
            "job_id": self.id,
            "total": self.total,
            "completed": self.completed,
            "percent": pct,
            "done": self.done,
        }
        if self.error is not None:
            out["error"] = self.error
        if self.done and self.result is not None:
            out["result"] = self.result
        return out


class DiscoveryJobs:
    """Thread-safe-enough for asyncio: a lock guards mutation, and `bump` is called from within the
    discovery gather. Lives on app.state.discovery_jobs."""

    def __init__(self) -> None:
        self._jobs: dict[str, DiscoveryJob] = {}
        self._lock = asyncio.Lock()
        self._seq = 0

    async def create(self, total: int) -> DiscoveryJob:
        async with self._lock:
            self._seq += 1
            # Not random/uuid: a monotonic id keeps eviction order obvious and needs no clock (the
            # workflow-sandbox ban on Date.now does not apply here, but a counter is simplest anyway).
            job = DiscoveryJob(id=f"disc-{self._seq}", total=total)
            self._jobs[job.id] = job
            # Evict oldest finished jobs beyond the cap.
            while len(self._jobs) > _MAX_JOBS:
                oldest = next(iter(self._jobs))
                del self._jobs[oldest]
            return job

    def bump(self, job_id: str) -> None:
        # Called per completed check from inside the gather — deliberately lock-free and cheap. A
        # single coroutine drives the counter (gather runs on one event loop), so += is safe here.
        job = self._jobs.get(job_id)
        if job is not None and not job.done:
            job.completed += 1

    async def finish(self, job_id: str, result: dict[str, Any]) -> None:
        async with self._lock:
            job = self._jobs.get(job_id)
            if job is not None:
                job.completed = job.total
                job.result = result
                job.done = True

    async def fail(self, job_id: str, error: str) -> None:
        async with self._lock:
            job = self._jobs.get(job_id)
            if job is not None:
                job.error = error
                job.done = True

    def get(self, job_id: str) -> DiscoveryJob | None:
        return self._jobs.get(job_id)
