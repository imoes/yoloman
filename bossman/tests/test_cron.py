"""Minimal cron matcher tests (services/cron.py)."""

from datetime import datetime

from bossman.services.cron import cron_matches, is_valid_cron, parse_cron


def test_every_15_minutes():
    assert cron_matches("*/15 * * * *", datetime(2026, 7, 19, 3, 0))
    assert cron_matches("*/15 * * * *", datetime(2026, 7, 19, 3, 15))
    assert not cron_matches("*/15 * * * *", datetime(2026, 7, 19, 3, 7))


def test_sunday_0300():
    # 2026-07-19 is a Sunday.
    assert cron_matches("0 3 * * 0", datetime(2026, 7, 19, 3, 0))
    assert not cron_matches("0 3 * * 0", datetime(2026, 7, 20, 3, 0))  # Monday
    assert not cron_matches("0 3 * * 0", datetime(2026, 7, 19, 4, 0))  # wrong hour


def test_weekday_range():
    # Mon-Fri 09:00
    assert cron_matches("0 9 * * 1-5", datetime(2026, 7, 20, 9, 0))  # Monday
    assert not cron_matches("0 9 * * 1-5", datetime(2026, 7, 19, 9, 0))  # Sunday


def test_dom_or_dow_semantics():
    # Both restricted -> OR: fires on the 1st OR on Mondays.
    assert cron_matches("0 0 1 * 1", datetime(2026, 7, 1, 0, 0))   # 1st (Wed)
    assert cron_matches("0 0 1 * 1", datetime(2026, 7, 20, 0, 0))  # a Monday


def test_validation():
    assert is_valid_cron("0 3 * * 0")
    assert not is_valid_cron("0 3 * *")   # only 4 fields
    assert not is_valid_cron("bogus")
    assert len(parse_cron("* * * * *")) == 5


def test_comma_and_step_lists():
    assert cron_matches("0,30 * * * *", datetime(2026, 7, 19, 5, 30))
    assert not cron_matches("0,30 * * * *", datetime(2026, 7, 19, 5, 15))


def test_out_of_range_values_are_refused_with_the_field():
    """`61 25 * * *` parsed to empty sets: a job that looked scheduled and could never fire."""
    from bossman.services.cron import cron_error, is_valid_cron

    assert not is_valid_cron("61 25 * * *")
    assert cron_error("61 25 * * *").startswith("minute:")
    assert cron_error("0 25 * * *").startswith("hour:")
    assert "step" in cron_error("*/0 * * * *")
    assert cron_error("0 3 * * 0") is None
