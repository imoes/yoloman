"""Integration test for the enrich step wired into qualify_packages (_enrich_template): a canned model
reply must pass the five gates and land as three artifacts (template.j2 + capabilities.json + normalised
schema.json) in the package dir; a reply that fails the gates must leave the originals untouched.

Runs the REAL gates (gonja render-check + ansible), so it is skipped where `go` or `ansible-core` is
absent. Run: .venv-host/bin/python -m pytest tests/test_qualify_enrich.py -q
"""
from __future__ import annotations

import asyncio
import importlib.util
import json
import shutil
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
# The tools live in the PACKAGE (bossman.tools), not in bossman/scripts/ — that directory held a
# patched duplicate of each, is untracked, and these tests were green only because it happened to
# exist on this machine. A clone could not run them.

from bossman.tools import enrich_gates as EG
from bossman.tools import qualify_packages as q

pytestmark = pytest.mark.skipif(
    shutil.which("go") is None or importlib.util.find_spec("ansible") is None,
    reason="enrich gates need `go` (gonja render-check) and ansible-core installed",
)


class FakeChat:
    """Returns a fixed two-artifact reply; duck-types ChatClient.complete_text."""

    def __init__(self, reply: str):
        self._reply = reply
        self.calls = 0

    async def complete_text(self, messages, **_) -> str:
        self.calls += 1
        return self._reply


def _seed_template(tmp: Path) -> Path:
    d = tmp / "widget"
    d.mkdir()
    # a deliberately UN-enriched template + a schema with type drift the normalizer must fix
    (d / "template.j2").write_text("port = {{ port }}\n")
    (d / "schema.json").write_text(json.dumps({"port": {"type": "integer", "default": 8080}}))
    (d / "sample.json").write_text(json.dumps({"port": 8080}))
    return d


def _good_reply() -> str:
    template = "# TCP port the widget listens on.\nport = {{ port | default(8080) }}\n"
    caps = json.dumps({"provides": [], "requires": [], "peer_injection": [], "confidence": "high"})
    return f"{EG.T_MARK}\n{template}\n{EG.C_MARK}\n{caps}"


def test_enrich_writes_three_artifacts_on_success(tmp_path, monkeypatch):
    monkeypatch.setattr(q, "TEMPLATES_DIR", tmp_path)
    d = _seed_template(tmp_path)
    chat = FakeChat(_good_reply())

    res = asyncio.run(q._enrich_template("widget", chat))

    assert res["enriched"] is True
    assert (d / "capabilities.json").exists()
    # template now carries the inline default + a comment (self-documenting)
    tmpl = (d / "template.j2").read_text()
    assert "| default(8080)" in tmpl and tmpl.lstrip().startswith("#")
    # schema was normalised: integer -> number
    schema = json.loads((d / "schema.json").read_text())
    assert schema["port"]["type"] == "number"


def test_enrich_leaves_originals_on_gate_failure(tmp_path, monkeypatch):
    monkeypatch.setattr(q, "TEMPLATES_DIR", tmp_path)
    d = _seed_template(tmp_path)
    original = (d / "template.j2").read_text()
    # a reply whose template lacks a default → gate 3 (ansible empty-context) fails every round
    bad_template = "port = {{ port }}\n"
    bad = f"{EG.T_MARK}\n{bad_template}\n{EG.C_MARK}\n{{}}"
    chat = FakeChat(bad)

    res = asyncio.run(q._enrich_template("widget", chat))

    assert res["enriched"] is False
    assert res.get("gate_fail")
    assert (d / "template.j2").read_text() == original      # untouched
    assert not (d / "capabilities.json").exists()
