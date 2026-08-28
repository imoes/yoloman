"""Offline test for the closed-loop lifecycle phase transition (no DB)."""
from datetime import datetime, timezone
from types import SimpleNamespace
from bossman.services import remediation as rem


def _run(): return SimpleNamespace(phase=None, verify_due_at=None, outcome=None)


def test_successful_apply_enters_verifying_when_verify_on():
    r = _run(); pol = SimpleNamespace(verify=True, verify_after_s=90)
    rem._set_verify_phase(r, pol, "ran", datetime(2026, 1, 1, tzinfo=timezone.utc))
    assert r.phase == "verifying" and r.verify_due_at is not None


def test_successful_apply_resolves_when_verify_off():
    r = _run(); pol = SimpleNamespace(verify=False, verify_after_s=60)
    rem._set_verify_phase(r, pol, "ran", datetime(2026, 1, 1, tzinfo=timezone.utc))
    assert r.phase == "resolved" and r.verify_due_at is None


def test_failed_apply_is_terminal_failed():
    r = _run(); pol = SimpleNamespace(verify=True, verify_after_s=60)
    rem._set_verify_phase(r, pol, "failed", datetime(2026, 1, 1, tzinfo=timezone.utc))
    assert r.phase == "failed" and r.outcome == "apply_failed"
