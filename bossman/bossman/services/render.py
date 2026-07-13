"""Human-readable value formatting, ported from Checkmk's render helpers
(checkmk/packages/cmk-plugin-apis/cmk/agent_based/v1/render.py) so Bossman's
service summaries read as professionally as Checkmk's: percentages with
sensible precision, byte sizes with IEC/SI prefixes, and time spans split into
days/hours/minutes instead of a raw float.
"""

from __future__ import annotations

import math
from collections.abc import Iterable

_TIME_UNITS = [
    ("years", 31536000),
    ("days", 86400),
    ("hours", 3600),
    ("minutes", 60),
    ("seconds", 1),
    ("milliseconds", 1e-3),
    ("microseconds", 1e-6),
]

_SIZE_PREFIXES_SI = ["", "k", "M", "G", "T", "P", "E", "Z", "Y"]
_SIZE_PREFIXES_IEC = _SIZE_PREFIXES_SI[:]
_SIZE_PREFIXES_IEC[1] = "K"


def _gen_timespan_chunks(seconds: float, nchunks: int) -> Iterable[str]:
    if seconds < 0:
        seconds = 0.0
    try:
        start = next(i for i, (_, v) in enumerate(_TIME_UNITS) if seconds >= v)
    except StopIteration:
        start = len(_TIME_UNITS) - 1
    for unit, scale in _TIME_UNITS[start : start + nchunks]:
        last_chunk = unit.endswith("seconds")
        value = round(seconds / scale) if last_chunk else int(seconds / scale)
        yield f"{value:.0f} {unit if value != 1 else unit[:-1]}"
        if last_chunk:
            break
        seconds %= scale


def timespan(seconds: float) -> str:
    """Render a duration split into its two largest units, e.g. 1046258s →
    '12 days 2 hours'.

    >>> timespan(1046258)
    '12 days 2 hours'
    >>> timespan(90)
    '1 minute 30 seconds'
    >>> timespan(0)
    '0 seconds'
    """
    ts = " ".join(_gen_timespan_chunks(float(seconds), nchunks=2))
    if ts == f"0 {_TIME_UNITS[-1][0]}":
        ts = "0 seconds"
    return ts


def _digits_left(value: float) -> int:
    try:
        return max(int(math.log10(abs(value)) + 1), 1)
    except ValueError:
        return 1


def _auto_scale(value: float, use_si_units: bool) -> tuple[str, str]:
    base = 1000.0 if use_si_units else 1024.0
    prefixes = _SIZE_PREFIXES_SI if use_si_units else _SIZE_PREFIXES_IEC
    try:
        log_value = int(math.log(abs(value), base))
    except ValueError:
        log_value = 0
    exponent = min(max(log_value, 0), len(prefixes) - 1)
    unit = (prefixes[exponent] + ("B" if use_si_units else "iB")).lstrip("i")
    scaled = float(value) / base**exponent
    fmt = f"%.{max(3 - _digits_left(scaled), 0)}f"
    return fmt % scaled, unit


def bytes(value: float) -> str:  # noqa: A001 - mirrors Checkmk's render.bytes
    """Render a byte count with an IEC prefix, e.g. 1048576 → '1.00 MiB'."""
    value_str, unit = _auto_scale(float(value), use_si_units=False)
    return f"{value_str if unit != 'B' else value_str.split('.')[0]} {unit}"


def disksize(value: float) -> str:
    """Render a disk size with an SI prefix, e.g. 1024 → '1.02 kB'."""
    value_str, unit = _auto_scale(float(value), use_si_units=True)
    return f"{value_str if unit != 'B' else value_str.split('.')[0]} {unit}"


def percent(percentage: float) -> str:
    """Render a percentage with Checkmk's precision rules.

    >>> percent(23.4203245)
    '23.42%'
    >>> percent(0.003)
    '<0.01%'
    >>> percent(0.0)
    '0%'
    """
    value = float(percentage)
    if value == 0.0:
        return "0%"
    if 0.0 < value < 0.01:
        return "<0.01%"
    return f"{value:.2f}%"


def number(value: float) -> str:
    """A plain numeric value (e.g. a load average), rounded to 2 decimals with
    trailing zeros stripped — no unit."""
    return f"{float(value):.2f}".rstrip("0").rstrip(".")
