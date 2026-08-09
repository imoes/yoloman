"""OLS + threshold-projection tests (services/forecast.py)."""

from datetime import datetime, timedelta, timezone

from bossman.services.forecast import _forecast_points, _ols, status_for
from bossman.services.metrics_query import SeriesPoint


def test_ols_perfect_line():
    slope, intercept = _ols([0, 1, 2, 3], [10, 12, 14, 16])
    assert round(slope, 6) == 2.0
    assert round(intercept, 6) == 10.0


def test_ols_flat():
    slope, intercept = _ols([0, 1, 2], [50, 50, 50])
    assert slope == 0.0 and intercept == 50.0


def _series(values: list[float], mount: str = "/") -> list[SeriesPoint]:
    t0 = datetime(2026, 6, 1, tzinfo=timezone.utc)
    return [SeriesPoint(time=t0 + timedelta(days=i), value=v, labels={"mount": mount}) for i, v in enumerate(values)]


def test_disk_filling_projects_eta():
    # 50% -> 60% over 10 days = +1%/day; to 90% from 60% = 30 more days.
    now = datetime(2026, 6, 1, tzinfo=timezone.utc) + timedelta(days=10)
    f = _forecast_points(_series([50 + i for i in range(11)]), threshold=90.0, now=now)
    assert f is not None
    assert round(f.slope_per_day, 3) == 1.0
    assert f.current == 60.0
    assert round(f.days_to_threshold, 0) == 30
    assert f.eta is not None


def test_shrinking_has_no_eta():
    now = datetime(2026, 6, 1, tzinfo=timezone.utc) + timedelta(days=4)
    f = _forecast_points(_series([80, 78, 76, 74, 72]), threshold=90.0, now=now)
    assert f is not None and f.days_to_threshold is None and f.eta is None


def test_already_over_threshold_is_zero():
    now = datetime(2026, 6, 1, tzinfo=timezone.utc) + timedelta(days=2)
    f = _forecast_points(_series([91, 92, 93]), threshold=90.0, now=now)
    assert f is not None and f.days_to_threshold == 0.0


def test_status_thresholds():
    assert status_for(None, 0.0, 30, 7) == "ok"
    assert status_for(3, 1.0, 30, 7) == "critical"
    assert status_for(20, 1.0, 30, 7) == "warning"
    assert status_for(90, 1.0, 30, 7) == "ok"
