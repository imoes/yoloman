"""Wave-planning tests for staged rollouts (services/rollout.py)."""

from bossman.services.rollout import plan_waves

HOSTS = [f"h{i}" for i in range(10)]


def test_canary_percent_rest():
    waves = plan_waves(HOSTS, [1, "25%", "rest"])
    assert [w["name"] for w in waves] == ["canary", "ring 1", "ring 2"]
    assert [len(w["agent_ids"]) for w in waves] == [1, 3, 6]  # 25% of 10 = ceil(2.5)=3
    # No host appears twice, all hosts covered, order preserved.
    flat = [a for w in waves for a in w["agent_ids"]]
    assert flat == HOSTS


def test_ints_only():
    waves = plan_waves(HOSTS, [2, 3])
    # Two explicit waves + a final "rest" wave for the leftover 5.
    assert [len(w["agent_ids"]) for w in waves] == [2, 3, 5]
    assert waves[0]["name"] == "wave 0"  # int canary of size 2 is not "canary"


def test_single_host():
    waves = plan_waves(["only"], [1, "25%", "rest"])
    assert len(waves) == 1
    assert waves[0]["name"] == "canary"
    assert waves[0]["agent_ids"] == ["only"]


def test_percent_rounds_up_to_at_least_one():
    waves = plan_waves(HOSTS, ["1%", "rest"])
    assert len(waves[0]["agent_ids"]) == 1  # ceil(0.1) floored at 1


def test_rest_alias_all():
    waves = plan_waves(HOSTS, [1, "all"])
    assert [len(w["agent_ids"]) for w in waves] == [1, 9]


def test_empty():
    assert plan_waves([], [1, "rest"]) == []


def test_strategy_shorter_than_fleet_gets_final_ring():
    waves = plan_waves(HOSTS, [1])
    assert [len(w["agent_ids"]) for w in waves] == [1, 9]
    assert waves[-1]["name"] == "ring 1"
