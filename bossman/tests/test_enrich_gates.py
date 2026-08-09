"""Deterministic (no-LLM) tests for the enrich gate module (scripts/enrich_gates.py) — the pure logic the
enrich batch relies on: schema normalization, capabilities parsing, and the field/vocabulary gates.

Run: .venv-host/bin/python -m pytest tests/test_enrich_gates.py -q
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]          # repo root (…/yolo-man)
sys.path.insert(0, str(ROOT / "bossman" / "scripts"))

import enrich_gates as G  # noqa: E402


# ── schema normalization ────────────────────────────────────────────────────

def test_normalize_canonicalises_types():
    schema = {"a": {"type": "boolean", "default": False}, "b": {"type": "integer", "default": 1},
              "c": {"type": "string", "default": ""}}
    norm, changed = G.normalize_schema(schema)
    assert changed is True
    assert norm["a"]["type"] == "bool"
    assert norm["b"]["type"] == "number"
    assert norm["c"]["type"] == "string"  # already canonical


def test_normalize_flattens_properties_and_fields_nesting():
    for inner_key in ("properties", "fields"):
        schema = {"rows": {"type": "list", "default": [],
                           "items": {"type": "object", inner_key: {"name": {"type": "string", "default": ""}}}}}
        norm, changed = G.normalize_schema(schema)
        assert changed is True
        # the flat field->spec map is lifted out of the object wrapper
        assert norm["rows"]["items"] == {"name": {"type": "string", "default": ""}}


def test_normalize_leaves_scalar_item_list_alone():
    schema = {"tags": {"type": "list", "default": [], "items": {"type": "string", "default": ""}}}
    norm, changed = G.normalize_schema(schema)
    assert changed is False
    assert norm["tags"]["items"] == {"type": "string", "default": ""}


def test_normalized_schema_passes_the_contract_gate():
    """A schema with type drift + nesting must be contract-clean after normalization (gate 1 precondition)."""
    sys.path.insert(0, str(ROOT / "bossman" / "scripts"))
    from batch_verify import verify_template_schema

    schema = {
        "flag": {"type": "boolean", "default": True},
        "custom": {"type": "object", "default": {}},  # object default is legitimate, must NOT be flagged
        "rows": {"type": "list", "default": [],
                 "items": {"type": "object", "fields": {"path": {"type": "string", "default": ""}}}},
    }
    norm, _ = G.normalize_schema(schema)
    assert verify_template_schema(norm) == []


# ── capabilities parsing + gates 4/5 ─────────────────────────────────────────

def test_parse_capabilities_strips_fence_and_defaults_keys():
    caps, problems = G.parse_capabilities('```json\n{"requires": []}\n```')
    assert problems == []
    assert caps["provides"] == [] and caps["peer_injection"] == [] and caps["confidence"] == "high"


def test_gate_fields_flags_unknown_field():
    caps = {"requires": [{"capability": "database", "backends": ["mysql"],
                          "fields": {"host": "db_host", "port": "nope_port"}}]}
    caps, _ = G.parse_capabilities(json.dumps(caps))
    schema = {"db_host": {"type": "string"}, "db_port": {"type": "number"}}
    problems = G.gate_fields(caps, schema)
    assert any("nope_port" in p for p in problems)
    assert not any("db_host" in p for p in problems)


def test_gate_vocab_accepts_canonical_rejects_invented():
    good, _ = G.parse_capabilities(json.dumps(
        {"requires": [{"capability": "database", "backends": ["mysql", "mariadb"]}]}))
    assert G.gate_vocab(good) == []
    bad, _ = G.parse_capabilities(json.dumps(
        {"requires": [{"capability": "frobnicate", "backends": ["x"]}]}))
    assert any("frobnicate" in p for p in G.gate_vocab(bad))
    # a backend that is not valid for the (valid) capability is caught too
    wrong, _ = G.parse_capabilities(json.dumps(
        {"provides": [{"capability": "database", "backend": "redis"}]}))
    assert any("redis" in p for p in G.gate_vocab(wrong))


def test_gate_vocab_review_bypasses():
    """confidence=review is the escape hatch: unknown tokens are allowed for a human to canonicalise."""
    caps, _ = G.parse_capabilities(json.dumps(
        {"requires": [{"capability": "quantum_db", "backends": ["qbits"]}], "confidence": "review"}))
    assert G.gate_vocab(caps) == []


def test_split_artifacts_separates_template_and_caps():
    reply = f"{G.T_MARK}\nport = 3306\n{G.C_MARK}\n{{\"provides\": []}}"
    tmpl, caps_raw = G.split_artifacts(reply)
    assert tmpl == "port = 3306"
    assert json.loads(caps_raw) == {"provides": []}
