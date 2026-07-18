"""Minimal 5-field cron matcher (no dependency).

Supports the standard `minute hour day-of-month month day-of-week` fields with
`*`, `*/step`, `a-b`, `a-b/step`, and comma lists — enough for recurring
maintenance/runbook schedules ("0 3 * * 0" = Sundays 03:00). day-of-week is
0-6 with 0=Sunday (7 also accepted for Sunday). A minute "matches now" is the
scheduler's fire signal, so no next-run arithmetic is needed.
"""

from __future__ import annotations

from datetime import datetime

_RANGES = {
    0: (0, 59),   # minute
    1: (0, 23),   # hour
    2: (1, 31),   # day of month
    3: (1, 12),   # month
    4: (0, 6),    # day of week (0=Sun)
}


def _parse_field(field: str, lo: int, hi: int) -> set[int]:
    out: set[int] = set()
    for part in field.split(","):
        part = part.strip()
        step = 1
        if "/" in part:
            part, _, s = part.partition("/")
            step = int(s)
        if part in ("*", ""):
            start, end = lo, hi
        elif "-" in part:
            a, _, b = part.partition("-")
            start, end = int(a), int(b)
        else:
            start = end = int(part)
        for v in range(start, end + 1, step):
            if lo <= v <= hi:
                out.add(v)
    return out


def parse_cron(expr: str) -> list[set[int]]:
    """Parse a 5-field cron expression into per-field allowed-value sets.
    Raises ValueError on a malformed expression."""
    fields = expr.split()
    if len(fields) != 5:
        raise ValueError(f"cron must have 5 fields (got {len(fields)}): {expr!r}")
    return [_parse_field(f, *_RANGES[i]) for i, f in enumerate(fields)]


def cron_matches(expr: str, when: datetime) -> bool:
    """Does `expr` fire at minute `when`? day-of-month and day-of-week are OR'd
    when BOTH are restricted (Vixie-cron semantics); otherwise AND."""
    m, h, dom, mon, dow = parse_cron(expr)
    wd = when.weekday()  # Mon=0..Sun=6
    cron_dow = (wd + 1) % 7  # -> Sun=0..Sat=6
    minute_ok = when.minute in m and when.hour in h and when.month in mon
    if not minute_ok:
        return False
    dom_restricted = len(dom) < 31
    dow_restricted = len(dow) < 7
    dom_ok = when.day in dom
    dow_ok = cron_dow in dow or (7 in dow and cron_dow == 0)
    if dom_restricted and dow_restricted:
        return dom_ok or dow_ok
    return dom_ok and dow_ok


def is_valid_cron(expr: str) -> bool:
    try:
        parse_cron(expr)
        return True
    except (ValueError, KeyError):
        return False
