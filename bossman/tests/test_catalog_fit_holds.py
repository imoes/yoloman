"""The fit check, run against the REAL catalogs, as a test.

The check exists so the rules stop being rediscovered — which only works if something runs it. A tool nobody
invokes is a rule nobody enforces, so this is the thing that invokes it: the same invariants, the same
budgets, failing the suite rather than waiting for someone to remember.
"""

import json

import pytest

from bossman.tools.check_catalog_fit import BASELINE, check


@pytest.fixture(scope="module")
def result():
    return check()


def test_no_invariant_is_violated(result):
    bad, _budget = result
    if bad:
        lines = [f"{rule}: {len(hits)} — e.g. {hits[0]}" for rule, hits in sorted(bad.items())]
        pytest.fail("the catalogs violate an invariant:\n  " + "\n  ".join(lines))


def test_no_budget_grew(result):
    """A budget is a count that cannot be zero yet. It may fall — then run
    `python -m bossman.tools.check_catalog_fit --baseline` — but a rise is a regression."""
    _bad, budget = result
    try:
        base = json.loads(BASELINE.read_text()).get("budgets") or {}
    except (OSError, ValueError):
        pytest.skip("no baseline recorded yet")
    grew = {k: (base[k], v) for k, v in budget.items() if k in base and v > base[k]}
    assert not grew, f"a tolerated count grew: {grew}"


def test_the_baseline_covers_every_budget(result):
    """A budget with no baseline entry is a count nobody is watching."""
    _bad, budget = result
    try:
        base = json.loads(BASELINE.read_text()).get("budgets") or {}
    except (OSError, ValueError):
        pytest.skip("no baseline recorded yet")
    missing = sorted(set(budget) - set(base))
    assert not missing, f"these budgets are unwatched: {missing} — re-run with --baseline"
