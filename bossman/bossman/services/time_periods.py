"""L4: time periods — "only page me during business hours", as a reusable object.

Ported from Checkmk's `cmk/utils/timeperiod.py` (`is_timeperiod_active`, ~30 LOC plus its
helpers). A period is weekday time ranges, plus date-specific exceptions, plus other
periods it excludes:

    ranges     {"monday": [["08:00", "17:00"]], "saturday": [["10:00", "14:00"]]}
    exceptions {"2026-12-24": [], "2026-12-31": [["08:00", "12:00"]]}
    excludes   ["company_holidays"]

Evaluation order, same as Checkmk's:

1. If any excluded period is currently active, this period is NOT active. Exclusion wins
   over everything, including exceptions.
2. If a date exception matches today, it decides — an empty range list means "closed all
   day", which is how a public holiday is expressed.
3. Otherwise today's weekday ranges decide.

Two deviations from the reference, and both are bug fixes rather than preferences.
Checkmk's `_is_timeperiod_excluded_via_timeperiod` and `_is_timeperiod_active_via_exception`
each place their `return` INSIDE the loop, so only the **first** exclude and only the
**first** date exception are ever evaluated; the rest are silently ignored, and which one
wins depends on dict insertion order. A period excluding both "holidays" and "maintenance"
would honour only one of them. Here every exclude and every matching exception is
considered.

Times are compared as zero-padded "HH:MM" strings, as in the reference — that makes
"24:00" a valid end-of-day marker (no 24th hour exists in a time object) and needs no
parsing. `_valid_time` enforces the padding that the comparison relies on.

**Which clock.** A window is read in a named timezone (`settings.time_period_timezone`),
never in UTC and never in whatever zone the process happens to run in. Checkmk uses the
site's local zone; ours would be the container's, which is UTC — and that is not a
theoretical difference: an 08:00-17:00 "business hours" period created at 18:30 CEST
reported itself as ACTIVE, because 18:30 local is 16:30 UTC. A window is a statement about
the people being paged, so the zone has to be stated rather than inherited.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Iterable, Mapping
from datetime import date, datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

logger = logging.getLogger(__name__)

WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")

# "HH:MM", 00:00-24:00. Zero-padded, because the range test is a string comparison.
_TIME = re.compile(r"^(?:[01]\d|2[0-4]):[0-5]\d$")

ALWAYS = "24x7"

# The built-in every-minute period. Kept here rather than in the DB seeding alone so the
# evaluator can answer for it even before anything is seeded.
ALWAYS_SPEC: dict = {
    "alias": "Always",
    "ranges": {day: [["00:00", "24:00"]] for day in WEEKDAYS},
    "exceptions": {},
    "excludes": [],
}


class TimePeriodError(ValueError):
    """A period definition that cannot be evaluated (bad time, bad date, unknown exclude)."""


def _valid_time(value: object) -> str:
    if not isinstance(value, str) or not _TIME.match(value):
        raise TimePeriodError(f"not a HH:MM time: {value!r}")
    return value


def normalise_ranges(raw: object) -> dict[str, list[list[str]]]:
    """Validates and normalises `{weekday: [[start, end], ...]}`.

    Rejects rather than repairs: a typo'd weekday key ("tuseday") would otherwise silently
    mean "never active on Tuesday", which is the kind of quiet gap a notification window
    must not have.
    """
    if raw in (None, {}):
        return {}
    if not isinstance(raw, Mapping):
        raise TimePeriodError("ranges must be an object keyed by weekday")
    out: dict[str, list[list[str]]] = {}
    for day, spans in raw.items():
        if day not in WEEKDAYS:
            raise TimePeriodError(f"unknown weekday {day!r} (expected one of {', '.join(WEEKDAYS)})")
        out[day] = _normalise_spans(spans, day)
    return out


def normalise_exceptions(raw: object) -> dict[str, list[list[str]]]:
    """Validates `{"YYYY-MM-DD": [[start, end], ...]}`; an empty list means closed all day."""
    if raw in (None, {}):
        return {}
    if not isinstance(raw, Mapping):
        raise TimePeriodError("exceptions must be an object keyed by YYYY-MM-DD")
    out: dict[str, list[list[str]]] = {}
    for day, spans in raw.items():
        try:
            date.fromisoformat(str(day))
        except ValueError as exc:
            raise TimePeriodError(f"not a YYYY-MM-DD date: {day!r}") from exc
        out[str(day)] = _normalise_spans(spans, str(day))
    return out


def _normalise_spans(spans: object, label: str) -> list[list[str]]:
    if spans in (None, []):
        return []
    if not isinstance(spans, (list, tuple)):
        raise TimePeriodError(f"{label}: expected a list of [start, end] pairs")
    out: list[list[str]] = []
    for span in spans:
        if not isinstance(span, (list, tuple)) or len(span) != 2:
            raise TimePeriodError(f"{label}: expected [start, end], got {span!r}")
        start, end = _valid_time(span[0]), _valid_time(span[1])
        if end <= start:
            # Not a wrap-around: Checkmk has no overnight span either, and silently
            # accepting 22:00-02:00 would make a window that never matches.
            raise TimePeriodError(f"{label}: {start}-{end} ends at or before it starts")
        out.append([start, end])
    return out


def resolve_zone(name: str) -> ZoneInfo | None:
    """The configured zone, or None if it cannot be loaded (caller then keeps `when` as is)."""
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        logger.warning("unknown time_period_timezone %r; evaluating windows in the given datetime's own zone", name)
        return None


def in_zone(when: datetime, zone: ZoneInfo | None) -> datetime:
    """`when` expressed in the zone the windows are written in."""
    if zone is None:
        return when
    if when.tzinfo is None:
        # Naive input means "already local" — attaching the zone is the only reading that
        # does not silently shift it.
        return when.replace(tzinfo=zone)
    return when.astimezone(zone)


def _in_spans(when: datetime, spans: Iterable[Iterable[str]]) -> bool:
    now = when.strftime("%H:%M")
    return any(start <= now <= end for start, end in spans)


def is_active(
    name: str,
    when: datetime,
    periods: Mapping[str, Mapping],
    _seen: frozenset[str] = frozenset(),
    *,
    zone: ZoneInfo | None = None,
) -> bool:
    """Is the named period active at `when`?

    `zone` is the clock the window is written in (see the module docstring). Callers pass
    `resolve_zone(settings.time_period_timezone)`; None means "read `when` as given", which
    is what the unit tests use to stay independent of any deployment setting.

    `periods` maps name → {alias, ranges, exceptions, excludes}. `24x7` answers True even
    if absent from the mapping, so a deployment that has not seeded it still behaves.

    `_seen` breaks exclude cycles. Checkmk does not guard against them at all — a period
    that (transitively) excludes itself recurses until the stack blows. A cycle here is
    treated as "not excluding", which keeps the period usable instead of taking the
    notification path down with it.
    """
    if name in _seen:
        return False
    spec = periods.get(name)
    if spec is None:
        if name == ALWAYS:
            return True
        raise TimePeriodError(f"unknown time period {name!r}")

    seen = _seen | {name}
    local = in_zone(when, zone)

    # 1. Exclusion wins over everything, including a date exception.
    for excluded in spec.get("excludes") or []:
        if excluded in periods or excluded == ALWAYS:
            if is_active(str(excluded), when, periods, seen, zone=zone):
                return False
        else:
            raise TimePeriodError(f"period {name!r} excludes unknown period {excluded!r}")

    # 2. A date exception for today decides — including "closed all day" (empty list).
    exceptions = spec.get("exceptions") or {}
    today = local.date().isoformat()
    if today in exceptions:
        return _in_spans(local, exceptions[today] or [])

    # 3. Today's weekday ranges.
    ranges = spec.get("ranges") or {}
    return _in_spans(local, ranges.get(WEEKDAYS[local.weekday()]) or [])
