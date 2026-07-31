"""The in-memory discovery-job registry that drives the percent bar."""

import pytest

from bossman.services.discovery_jobs import DiscoveryJobs, _MAX_JOBS


@pytest.mark.asyncio
async def test_percent_tracks_completed_and_caps_below_100_until_done():
    jobs = DiscoveryJobs()
    job = await jobs.create(total=4)
    assert job.snapshot()["percent"] == 0

    jobs.bump(job.id)
    jobs.bump(job.id)
    # 2/4 = 50%, and NOT done yet.
    snap = jobs.get(job.id).snapshot()
    assert snap["percent"] == 50 and snap["completed"] == 2 and snap["done"] is False

    # Even if every unit is counted, percent stays <100 until finish() — so the bar never shows 100
    # while the reconcile/commit tail is still running.
    jobs.bump(job.id)
    jobs.bump(job.id)
    assert jobs.get(job.id).snapshot()["percent"] == 99

    await jobs.finish(job.id, {"proposals": []})
    done = jobs.get(job.id).snapshot()
    assert done["percent"] == 100 and done["done"] is True
    assert done["result"] == {"proposals": []}


@pytest.mark.asyncio
async def test_total_zero_never_divides_by_zero():
    jobs = DiscoveryJobs()
    job = await jobs.create(total=0)
    assert job.snapshot()["percent"] == 0
    await jobs.finish(job.id, {"proposals": []})
    assert jobs.get(job.id).snapshot()["percent"] == 100


@pytest.mark.asyncio
async def test_failure_is_reported_and_marks_done():
    jobs = DiscoveryJobs()
    job = await jobs.create(total=3)
    await jobs.fail(job.id, "agent unreachable")
    snap = jobs.get(job.id).snapshot()
    assert snap["done"] is True
    assert snap["error"] == "agent unreachable"
    assert "result" not in snap
    # A failed job's bar must not read 100% (that would look like success).
    assert snap["percent"] != 100


@pytest.mark.asyncio
async def test_bump_after_done_is_ignored():
    jobs = DiscoveryJobs()
    job = await jobs.create(total=2)
    await jobs.finish(job.id, {})
    jobs.bump(job.id)  # a late straggler must not push completed past total
    assert jobs.get(job.id).snapshot()["completed"] == 2


@pytest.mark.asyncio
async def test_old_jobs_are_evicted():
    jobs = DiscoveryJobs()
    first = await jobs.create(total=1)
    for _ in range(_MAX_JOBS + 5):
        await jobs.create(total=1)
    # The very first job has aged out; recent ones remain.
    assert jobs.get(first.id) is None


@pytest.mark.asyncio
async def test_missing_job_snapshot_is_none():
    jobs = DiscoveryJobs()
    assert jobs.get("disc-999") is None
