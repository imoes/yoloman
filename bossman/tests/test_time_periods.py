"""L4 evaluator, ported from Checkmk's is_timeperiod_active — pure, no DB.

Includes the two cases Checkmk itself gets wrong (its `return` sits inside the loop, so
only the first exclude and only the first date exception are evaluated).
"""

from datetime import datetime, timezone

import pytest

from bossman.services.time_periods import (
    ALWAYS,
    ALWAYS_SPEC,
    TimePeriodError,
    is_active,
    normalise_exceptions,
    normalise_ranges,
)

# 2026-07-30 is a Thursday; 2026-08-01 a Saturday.
THU_09 = datetime(2026, 7, 30, 9, 0, tzinfo=timezone.utc)
THU_19 = datetime(2026, 7, 30, 19, 0, tzinfo=timezone.utc)
SAT_09 = datetime(2026, 8, 1, 9, 0, tzinfo=timezone.utc)

BUSINESS = {
    "alias": "Business hours",
    "ranges": {d: [["08:00", "17:00"]] for d in ("monday", "tuesday", "wednesday", "thursday", "friday")},
    "exceptions": {},
    "excludes": [],
}


def test_business_hours_in_and_out():
    periods = {"business": BUSINESS}
    assert is_active("business", THU_09, periods) is True
    assert is_active("business", THU_19, periods) is False
    assert is_active("business", SAT_09, periods) is False, "no saturday range at all"


def test_always_is_active_even_when_not_seeded():
    """A deployment that has not seeded 24x7 must still behave, not raise."""
    assert is_active(ALWAYS, THU_19, {}) is True
    assert is_active(ALWAYS, SAT_09, {ALWAYS: ALWAYS_SPEC}) is True


def test_end_of_day_marker():
    """"24:00" is why the comparison is on strings — no time object has a 24th hour."""
    periods = {"nights": {"ranges": {"thursday": [["17:00", "24:00"]]}}}
    assert is_active("nights", THU_19, periods) is True


def test_boundaries_are_inclusive_like_the_reference():
    periods = {"b": {"ranges": {"thursday": [["09:00", "17:00"]]}}}
    assert is_active("b", datetime(2026, 7, 30, 9, 0, tzinfo=timezone.utc), periods) is True
    assert is_active("b", datetime(2026, 7, 30, 17, 0, tzinfo=timezone.utc), periods) is True
    assert is_active("b", datetime(2026, 7, 30, 17, 1, tzinfo=timezone.utc), periods) is False


def test_a_date_exception_overrides_the_weekday():
    periods = {"b": {"ranges": {"thursday": [["08:00", "17:00"]]}, "exceptions": {"2026-07-30": [["20:00", "22:00"]]}}}
    assert is_active("b", THU_09, periods) is False, "the exception replaces the weekday ranges"
    assert is_active("b", datetime(2026, 7, 30, 21, 0, tzinfo=timezone.utc), periods) is True


def test_an_empty_exception_means_closed_all_day():
    """How a public holiday is expressed."""
    periods = {"b": {"ranges": {"thursday": [["08:00", "17:00"]]}, "exceptions": {"2026-07-30": []}}}
    assert is_active("b", THU_09, periods) is False


def test_exclusion_beats_an_exception():
    """Checkmk checks exclusion first, before exceptions — kept deliberately."""
    periods = {
        "b": {"ranges": {}, "exceptions": {"2026-07-30": [["00:00", "24:00"]]}, "excludes": ["frozen"]},
        "frozen": {"ranges": {"thursday": [["00:00", "24:00"]]}},
    }
    assert is_active("b", THU_09, periods) is False


def test_every_exclude_is_evaluated_not_only_the_first():
    """The Checkmk bug: its `return` is inside the loop over excludes.

    A period excluding both "holidays" and "maintenance" honoured only whichever came
    first in the dict, so the second exclusion silently did nothing.
    """
    periods = {
        "b": {"ranges": {"thursday": [["00:00", "24:00"]]}, "excludes": ["quiet", "maintenance"]},
        "quiet": {"ranges": {}},  # never active — must NOT end the search
        "maintenance": {"ranges": {"thursday": [["08:00", "10:00"]]}},
    }
    assert is_active("b", THU_09, periods) is False, "the second exclude must still apply"


def test_every_exception_is_evaluated_not_only_the_first():
    """Same bug shape on the exception side, and dict order decided the winner."""
    periods = {
        "b": {
            "ranges": {"thursday": [["00:00", "24:00"]]},
            "exceptions": {"2026-12-24": [], "2026-07-30": [["20:00", "21:00"]]},
        }
    }
    assert is_active("b", THU_09, periods) is False, "today's exception must be found, not just the first key"


def test_an_exclude_cycle_does_not_recurse_forever():
    """Checkmk has no cycle guard here at all; a self-excluding period blows the stack."""
    periods = {
        "a": {"ranges": {"thursday": [["00:00", "24:00"]]}, "excludes": ["b"]},
        "b": {"ranges": {"thursday": [["00:00", "24:00"]]}, "excludes": ["a"]},
    }
    assert is_active("a", THU_09, periods) is False


def test_unknown_period_and_unknown_exclude_are_errors():
    with pytest.raises(TimePeriodError):
        is_active("nope", THU_09, {})
    with pytest.raises(TimePeriodError):
        is_active("b", THU_09, {"b": {"excludes": ["ghost"]}})


def test_ranges_reject_a_typoed_weekday():
    """"tuseday" would otherwise silently mean "never active on Tuesday"."""
    with pytest.raises(TimePeriodError):
        normalise_ranges({"tuseday": [["08:00", "17:00"]]})


def test_ranges_reject_unpadded_or_impossible_times():
    for bad in ("8:00", "08:60", "25:00", "0800", ""):
        with pytest.raises(TimePeriodError):
            normalise_ranges({"monday": [[bad, "17:00"]]})


def test_ranges_reject_an_inverted_span():
    """22:00-02:00 is not a wrap-around here (nor in Checkmk) — it would never match."""
    with pytest.raises(TimePeriodError):
        normalise_ranges({"monday": [["22:00", "02:00"]]})
    with pytest.raises(TimePeriodError):
        normalise_ranges({"monday": [["09:00", "09:00"]]})


def test_ranges_and_exceptions_normalise_empty_input():
    assert normalise_ranges(None) == {}
    assert normalise_ranges({}) == {}
    assert normalise_exceptions({"2026-12-24": None}) == {"2026-12-24": []}


def test_exceptions_reject_a_non_date_key():
    with pytest.raises(TimePeriodError):
        normalise_exceptions({"christmas": [["08:00", "12:00"]]})


def test_normalised_output_is_plain_lists():
    """Stored as JSONB — tuples would not round-trip identically."""
    out = normalise_ranges({"monday": [("08:00", "17:00")]})
    assert out == {"monday": [["08:00", "17:00"]]}


# ---------------------------------------------------------------------------
# Which clock a window is read in — found live, not by reasoning


def test_the_same_instant_differs_by_zone():
    """The live bug: an 08:00-17:00 window reported ACTIVE at 18:30 CEST.

    18:30 in Europe/Berlin is 16:30 UTC, and the container runs UTC (verified: host
    18:30 CEST, container 16:30 UTC). Read in UTC the window matched; read in the zone the
    people actually work in, it does not. A window is a statement about those people, so
    the zone has to be explicit rather than inherited from whatever the image happens to
    be set to.
    """
    from datetime import timezone as _tz

    from bossman.services.time_periods import resolve_zone

    periods = {"b": {"ranges": {"thursday": [["08:00", "17:00"]]}}}
    utc_1630 = datetime(2026, 7, 30, 16, 30, tzinfo=_tz.utc)  # 18:30 in Berlin

    assert is_active("b", utc_1630, periods) is True, "documents the wrong reading"
    assert is_active("b", utc_1630, periods, zone=resolve_zone("Europe/Berlin")) is False


def test_the_zone_can_shift_the_weekday_too():
    """Not just the hour: 23:30 UTC Thursday is already Friday in Tokyo."""
    from datetime import timezone as _tz

    from bossman.services.time_periods import resolve_zone

    periods = {"b": {"ranges": {"friday": [["08:00", "09:00"]]}}}
    thu_2330_utc = datetime(2026, 7, 30, 23, 30, tzinfo=_tz.utc)  # Fri 08:30 in Tokyo
    assert is_active("b", thu_2330_utc, periods) is False
    assert is_active("b", thu_2330_utc, periods, zone=resolve_zone("Asia/Tokyo")) is True


def test_an_unknown_zone_falls_back_instead_of_crashing():
    """A typo'd setting must not take the notification path down with it."""
    from bossman.services.time_periods import resolve_zone

    assert resolve_zone("Europe/Berlim") is None
    periods = {"b": {"ranges": {"thursday": [["08:00", "17:00"]]}}}
    assert is_active("b", THU_09, periods, zone=resolve_zone("nonsense/zone")) is True


def test_a_naive_datetime_is_read_as_already_local():
    """Attaching the zone is the only reading that does not silently shift the value."""
    from bossman.services.time_periods import in_zone, resolve_zone

    zone = resolve_zone("Europe/Berlin")
    naive = datetime(2026, 7, 30, 9, 0)
    assert in_zone(naive, zone).strftime("%H:%M") == "09:00"
