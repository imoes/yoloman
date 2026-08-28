"""Offline tests for the infra knowledge indexer's pure helpers (no DB/LLM)."""
from __future__ import annotations

from bossman.services import knowledge_index as ki


def test_hash_is_stable_and_content_addressed():
    assert ki._hash("abc") == ki._hash("abc")
    assert ki._hash("abc") != ki._hash("abd")


def test_clip_bounds_long_text():
    long = "x" * (ki._MAX_CARD_CHARS + 500)
    out = ki._clip(long)
    assert len(out) <= ki._MAX_CARD_CHARS + 2  # + " …"
    assert out.endswith("…")
    assert ki._clip("short") == "short"


def test_facts_summary_extracts_common_keys():
    facts = {"os": {"pretty_name": "Debian 12", "kernel": "6.1.0"},
             "cpu": {"count": 4}, "memory": {"total_mb": 8192}}
    s = ki._facts_summary(facts)
    assert "Debian 12" in s and "kernel 6.1.0" in s and "4 CPU" in s and "8192 MB RAM" in s


def test_facts_summary_empty_is_blank():
    assert ki._facts_summary({}) == ""
