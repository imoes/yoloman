"""L7: flapping on the reference algorithm — pure, no DB.

The old test was "5 state changes within 30 minutes", which is not normalised against how
often the service is actually checked: a service polled every 10 minutes can only produce
three results in that window and so could never flap, while one polled every 20 seconds flaps
on a handful of blips out of ninety checks.
"""

from bossman.services.monitoring import (
    _FLAP_HISTORY,
    _FLAP_START_PCT,
    _FLAP_STOP_PCT,
    append_state_history,
    is_flapping_now,
    percent_state_change,
)

STABLE = ["OK"] * 21
ALTERNATING = (["OK", "CRIT"] * 11)[:21]


def test_a_stable_service_is_zero_percent():
    assert percent_state_change(STABLE) == 0.0
    assert is_flapping_now(STABLE, False) is False


def test_constant_alternation_is_a_hundred_percent():
    assert percent_state_change(ALTERNATING) == 100.0
    assert is_flapping_now(ALTERNATING, False) is True


def test_recent_changes_weigh_more_than_old_ones():
    """Nagios weights transitions 0.8 (oldest) to 1.2 (newest): instability that just started
    matters more than instability that has since settled."""
    recent = ["OK"] * 18 + ["CRIT", "OK", "CRIT"]
    old = ["OK", "CRIT", "OK"] + ["CRIT"] * 18
    assert percent_state_change(recent) > percent_state_change(old)


def test_a_brand_new_service_does_not_flap():
    """One result has no history to be unstable in; anything but 0.0 would flag every new
    service the moment it appears."""
    assert percent_state_change([]) == 0.0
    assert percent_state_change(["OK"]) == 0.0
    assert is_flapping_now(["OK"], False) is False


def test_two_results_are_handled_without_a_division_by_zero():
    """The weight ramp needs pairs-1 as a divisor, which is 0 when there is exactly one pair."""
    assert percent_state_change(["OK", "OK"]) == 0.0
    assert percent_state_change(["OK", "CRIT"]) == 100.0


def test_hysteresis_starts_high_and_stops_low():
    """Without the gap a service near the threshold would be declared flapping and
    un-flapping on alternating checks — flapping in the flag itself."""
    # ~12%: above the stop threshold, below the start threshold.
    middling = ["OK"] * 19 + ["CRIT", "OK"]
    pct = percent_state_change(middling)
    assert _FLAP_STOP_PCT < pct < _FLAP_START_PCT, f"the fixture must sit in the gap, is {pct}"

    assert is_flapping_now(middling, False) is False, "not yet flapping — must not start here"
    assert is_flapping_now(middling, True) is True, "already flapping — must not stop here either"


def test_flapping_stops_once_it_settles():
    settled = ["CRIT", "OK"] + ["OK"] * 19
    assert percent_state_change(settled) < _FLAP_STOP_PCT
    assert is_flapping_now(settled, True) is False


def test_the_history_is_fixed_length_and_oldest_first():
    """It lives on the Service row, so it must never grow."""
    history: list = []
    for i in range(50):
        history = append_state_history(history, "OK" if i % 2 else "CRIT")
    assert len(history) == _FLAP_HISTORY
    assert history[-1] == "OK", "the newest result is last"


def test_the_history_tolerates_a_null_column():
    """Existing rows have no history until their next check."""
    assert append_state_history(None, "OK") == ["OK"]


def test_unknown_counts_as_a_change_like_any_other_state():
    """A service oscillating between CRIT and UNKNOWN is unstable too, not "half broken"."""
    assert percent_state_change(["CRIT", "UNKNOWN", "CRIT", "UNKNOWN"]) == 100.0
