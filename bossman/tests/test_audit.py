"""Categorization + target-extraction tests (services/audit.py)."""

from bossman.services.audit import _target_from_path, categorize


def test_categorize():
    assert categorize("/api/v1/compliance-rules") == "policy"
    assert categorize("/api/v1/config-policies") == "config"
    assert categorize("/api/v1/rollouts/x/start") == "execution"
    assert categorize("/api/v1/users") == "access"
    assert categorize("/api/v1/auth/login") == "auth"
    assert categorize("/api/v1/something-else") == "other"


def test_target_from_path():
    assert _target_from_path("/api/v1/compliance-rules") is None
    assert _target_from_path("/api/v1/compliance-rules/abc-123") == "abc-123"
    assert _target_from_path("/api/v1/rollouts/abc/start") == "abc/start"
