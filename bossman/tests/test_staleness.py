"""L1: an aged-out reading is not a verdict about now.

The bug this pins down, measured on the live DB before the fix:

    poll-f6411610   newest metric 26 days old   CPU load   OK   last_checked 3 seconds ago
    poll-6adfaad6   newest metric 24 days old   Disk /     OK   last_checked 3 seconds ago

Two individually reasonable decisions combined into a false statement. `evaluate_host`
runs whether or not the host was reached, so a transient pull failure does not freeze
evaluation (poller.py). And the value it judged was fetched with no time bound at all,
so a dead host's last reading was re-confirmed as OK every single poll cycle.
"""

from datetime import datetime, timedelta, timezone

from bossman.services.monitoring import _no_data_output, is_stale_sample, stale_after_for

NOW = datetime(2026, 7, 30, 12, 0, tzinfo=timezone.utc)


class _S:
    """Only the two fields stale_after_for reads."""

    def __init__(self, factor=4.0, interval=60):
        self.staleness_factor = factor
        self.poll_interval_seconds = interval


def test_window_is_derived_from_the_poll_interval():
    """A deployment polling every 10 minutes must not be judged by a 60-second assumption."""
    assert stale_after_for(_S(interval=60)) == timedelta(seconds=240)
    assert stale_after_for(_S(interval=600)) == timedelta(seconds=2400)


def test_window_clears_the_measured_healthy_range():
    """Healthy hosts measured at 61-108 s, worst sample gap 120 s — all must pass as fresh.

    This is why the factor is 4 and not Checkmk's 1.5: 1.5 x 60 s = 90 s would have
    declared healthy hosts stale, because unlike Checkmk's core we do not produce the
    reading at check time — it crosses agent-sample -> poll -> evaluate first.
    """
    window = stale_after_for(_S())
    for age in (61, 81, 108, 120):
        assert not is_stale_sample(NOW - timedelta(seconds=age), NOW, window), f"{age}s must be fresh"
    assert stale_after_for(_S(factor=1.5)) < timedelta(seconds=108), "documents why 1.5 is too tight"


def test_the_dead_host_from_the_bug_report_is_stale():
    window = stale_after_for(_S())
    assert is_stale_sample(NOW - timedelta(days=26), NOW, window)
    assert is_stale_sample(NOW - timedelta(minutes=5), NOW, window)


def test_boundary_is_inclusive_of_exactly_the_window():
    """Exactly at the limit still counts as fresh; one second past it does not."""
    window = stale_after_for(_S())
    assert not is_stale_sample(NOW - window, NOW, window)
    assert is_stale_sample(NOW - window - timedelta(seconds=1), NOW, window)


def test_no_sample_at_all_is_stale():
    """A never-sampled series must not be mistaken for a fresh one."""
    assert is_stale_sample(None, NOW, stale_after_for(_S()))


def test_output_names_the_duration_and_the_never_sampled_case():
    """"UNKNOWN" alone cannot distinguish "never sampled" from "gone since Tuesday"."""
    assert _no_data_output(None, NOW) == "no data (never sampled)"
    msg = _no_data_output(NOW - timedelta(days=26), NOW)
    assert msg.startswith("no data for ") and "26" in msg


def test_a_future_timestamp_is_not_stale():
    """Clock skew on an agent must not make a just-delivered sample look ancient."""
    assert not is_stale_sample(NOW + timedelta(seconds=30), NOW, stale_after_for(_S()))
