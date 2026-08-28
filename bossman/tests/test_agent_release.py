"""Offline tests for the agent release channel's version logic (no network)."""
from __future__ import annotations

from bossman.services import agent_release as ar


def test_norm_version_strips_tag_prefixes():
    assert ar._norm_version("agent-v0.57.43") == "0.57.43"
    assert ar._norm_version("v1.2.3") == "1.2.3"
    assert ar._norm_version("0.57.43") == "0.57.43"


def test_is_newer_numeric():
    assert ar.is_newer("0.57.44", "0.57.43") is True
    assert ar.is_newer("0.58.0", "0.57.43") is True
    assert ar.is_newer("0.57.43", "0.57.43") is False
    assert ar.is_newer("0.57.42", "0.57.43") is False


def test_is_newer_handles_missing_or_nonnumeric_installed():
    # A host that never reported a version is behind anything released.
    assert ar.is_newer("0.57.43", "") is True
    # Non-numeric installed marker (e.g. a dev/test stamp) counts as behind a real release.
    assert ar.is_newer("0.57.43", "0.0.0-test") is True
    # No candidate version → never "newer".
    assert ar.is_newer("", "0.57.43") is False


def test_snapshot_shape_before_any_check():
    snap = ar.snapshot()
    assert set(snap) >= {"enabled", "checked_at", "error", "latest"}
