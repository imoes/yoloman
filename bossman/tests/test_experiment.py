"""Tuning experiments (services/experiment.py, docs/kernel-tuning.md block 5).

Pinned: the verdict is a closed set and an effect inside the noise is no_difference, never better; runs alternate
A/B and every B is undone with the module's own undo; the host ends at A (checked); a candidate the host refuses,
or one the host already has, is refused before anything changes; a reboot-needing tunable is refused without a
snapshot; the MCP tools start, follow and list experiments.
"""
from __future__ import annotations

import pytest
from mcp.server.fastmcp.exceptions import ToolError
from sqlalchemy import delete

from bossman.db.models import TuningExperiment
from bossman.mcp.server import build_mcp_server
from bossman.services import experiment as ex
from bossman.services.catalog import CatalogCache
from tests.test_mcp_server import FakeEmbeddingClient, _call, _make_agent, _settings, session_factory  # noqa: F401


def test_judge_names_every_verdict():
    # hackbench seconds (lower is better): B clearly faster, ranges apart, beyond the noise band → better.
    better = ex.judge([4.6, 4.7, 4.65, 4.68, 4.62], [4.30, 4.31, 4.28, 4.33, 4.29], higher_is_better=False)
    assert better["verdict"] == "better" and better["delta_pct"] < 0 and better["p_value"] < 0.05
    # The real run on Ubuntu 26.04 (fair vs scx_bpfland, hackbench s): median -9.4 %, noise 4.3 %, one B outlier.
    # The old "ranges must not overlap" rule said no_difference; the rank test says: outside the noise, but with
    # 5+5 runs not significant (exact two-sided p = 38/252 = 0.151) — inconclusive, run more.
    real = ex.judge([4.793, 5.287, 4.668, 4.826, 4.812], [4.291, 5.535, 4.302, 4.36, 4.489], higher_is_better=False)
    assert real["verdict"] == "inconclusive" and abs(real["p_value"] - 0.1508) < 0.001 and "run more" in real["reason"]
    # Three a side cannot be significant (exact p >= 0.1): inconclusive even when cleanly apart.
    hint = ex.judge([4.515, 5.102, 4.667], [4.308, 4.111, 4.391], higher_is_better=False)
    assert hint["verdict"] == "inconclusive"
    # A median move below the minimum effect → no_difference.
    same = ex.judge([10, 11, 12, 10.5, 11.5], [10.8, 11.6, 12.2, 10.9, 11.1], higher_is_better=True)
    assert same["verdict"] == "no_difference" and "below the 2 %" in same["reason"]
    # The 10+10 run on Ubuntu 26.04: -6.6 % with p = 0.0015 although single runs scatter ±8 % → better.
    # (The noise-band rule called this no_difference — the band measures single runs, not the median.)
    ten = ex.judge([4.625, 5.377, 4.728, 4.544, 4.868, 4.737, 4.852, 5.389, 4.615, 4.681],
                   [4.592, 4.541, 4.152, 4.125, 4.457, 4.278, 4.168, 4.922, 4.382, 4.56], higher_is_better=False)
    assert ten["verdict"] == "better" and ten["p_value"] < 0.005 and ten["noise_pct"] > abs(ten["delta_pct"])
    # Fewer than MIN_RUNS a side → inconclusive, with the reason.
    few = ex.judge([1.0, 1.1], [2.0, 2.1], higher_is_better=True)
    assert few["verdict"] == "inconclusive" and "at least 3" in few["reason"]
    # Wild scatter → inconclusive, not a verdict.
    noisy = ex.judge([10, 30, 50, 12, 45], [100, 140, 180, 120, 160], higher_is_better=True)
    assert noisy["verdict"] == "inconclusive" and "scatter" in noisy["reason"]
    # IOPS (higher is better) dropping clearly → worse.
    worse = ex.judge([22000, 22100, 21950, 22050], [19000, 19100, 18950, 19050], higher_is_better=True)
    assert worse["verdict"] == "worse"
    assert {better["verdict"], same["verdict"], few["verdict"], worse["verdict"]} <= set(ex.VERDICTS)


class _Host:
    """A fake agent: sched_ext with state, and a benchmark whose time depends on whether the candidate is on."""

    def __init__(self, reboot: bool = False):
        self.on = False
        self.log: list[str] = []
        self.reboot = reboot

    async def call_tool(self, name, body, timeout=None):
        dry = body.get("dry_run")
        if name == "yoloman.sched_ext":
            want_on = body.get("state", "enabled") == "enabled"
            changed = want_on != self.on
            if not dry:
                self.log.append("B" if want_on else "A")
                self.on = want_on
            return {"changed": changed, "data": {"persistence": "pending_reboot" if self.reboot else "live",
                                                 "rollback": {"state": "disabled"} if want_on else {"state": "enabled", "scheduler": "bpfland"}}}
        if name == "yoloman.benchmark":
            n = len([x for x in self.log if x.startswith("bench")])
            self.log.append(f"bench-{'B' if self.on else 'A'}")
            value = (4.30 if self.on else 4.65) + 0.01 * (n % 3)
            return {"changed": True, "data": {"metric": "hackbench_time", "value": value, "unit": "s", "higher_is_better": False}}
        raise AssertionError(f"unexpected tool {name}")


@pytest.fixture
async def host(db_session):
    agent = await _make_agent(db_session, address="10.250.9.9:18051")
    yield agent
    await db_session.execute(delete(TuningExperiment).where(TuningExperiment.agent_id == agent.id))
    await db_session.commit()


async def test_experiment_alternates_undoes_and_ends_at_a(host, session_factory, tmp_path):
    fake = _Host()
    mcp = build_mcp_server(session_factory, _settings(str(tmp_path)), CatalogCache(str(tmp_path)), FakeEmbeddingClient(),
                           client_factory=lambda a, s: fake)
    started = await _call(mcp, "experiment_start", {"host": host.name, "tunable": "sched_ext",
                                                    "params": {"scheduler": "bpfland", "persistent": False},
                                                    "profile": "sched_throughput", "runs": 5,
                                                    "hypothesis": "bpfland shortens hackbench"})
    assert started["status"] == "running"
    done = await _call(mcp, "experiment_status", {"experiment_id": started["id"], "wait_s": 30})
    for _ in range(10):
        if done["status"] != "running":
            break
        done = await _call(mcp, "experiment_status", {"experiment_id": started["id"], "wait_s": 30})
    assert done["status"] == "done" and done["verdict"] == "better", done
    assert [m["side"] for m in done["measurements"]] == ["A", "B"] * 5
    assert fake.log == ["bench-A", "B", "bench-B", "A"] * 5, "B is set before and undone after every B run"
    assert done["summary"]["restored"] is True and not fake.on and done["undo"] == {"state": "disabled"}
    assert done["summary"]["order"] == "alternating A/B" and done["summary"]["unit"] == "s"
    listed = await _call(mcp, "experiments", {"host": host.name})
    assert listed[0]["id"] == started["id"] and "measurements" not in listed[0]


async def test_experiment_refusals_change_nothing(host, session_factory, tmp_path):
    fake = _Host()
    fake.on = True   # the candidate is what the host already runs
    mcp = build_mcp_server(session_factory, _settings(str(tmp_path)), CatalogCache(str(tmp_path)), FakeEmbeddingClient(),
                           client_factory=lambda a, s: fake)
    with pytest.raises(ToolError, match="already has"):
        await _call(mcp, "experiment_start", {"host": host.name, "tunable": "sched_ext", "params": {"scheduler": "bpfland"},
                                              "profile": "sched_throughput"})
    with pytest.raises(ToolError, match="runs must be"):
        await _call(mcp, "experiment_start", {"host": host.name, "tunable": "sched_ext", "params": {"scheduler": "bpfland"},
                                              "profile": "sched_throughput", "runs": 1})
    reboot = _Host(reboot=True)
    mcp2 = build_mcp_server(session_factory, _settings(str(tmp_path)), CatalogCache(str(tmp_path)), FakeEmbeddingClient(),
                            client_factory=lambda a, s: reboot)
    with pytest.raises(ToolError, match="only after a reboot"):
        await _call(mcp2, "experiment_start", {"host": host.name, "tunable": "sched_ext", "params": {"scheduler": "bpfland"},
                                               "profile": "sched_throughput"})
    with pytest.raises(ToolError, match="not a VM Bossman deployed"):
        await _call(mcp2, "experiment_start", {"host": host.name, "tunable": "sched_ext", "params": {"scheduler": "bpfland"},
                                               "profile": "sched_throughput", "snapshot": True})
    assert fake.log == [] and reboot.log == [], "a refused experiment changes nothing on the host"
