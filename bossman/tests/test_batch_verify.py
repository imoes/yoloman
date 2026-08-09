"""Mocked, deterministic verification of the two LLM batches — no live model.

- Template qualify (qualify_packages): output-contract checks (batch_verify) +
  the write-path flatten + the grammar contract that forbids object defaults.
- Check translate (retranslate_checks / _mcp_pipeline.translate_one): the
  starlark-check gate + runnable gate, driven by a FakeChatClient and a FakeLib
  that shells to the real bin/starlark-check.
- UI execution qualification: a check is classified snmp | local | service
  (detect_check_execution deterministic for snmp; the local<->service split via
  the LLM, mocked).

Run: .venv-host/bin/python -m pytest tests/test_batch_verify.py -q
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]          # repo root (…/yolo-man)
BOSSMAN = ROOT / "bossman"
sys.path.insert(0, str(BOSSMAN / "scripts"))

import batch_verify as bv                                     # noqa: E402
import qualify_packages as q                                 # noqa: E402
from _mcp_pipeline import translate_one                      # noqa: E402
from bossman.services.checkmk_translation import (           # noqa: E402
    build_checkmk_messages, detect_check_execution,
)
from bossman.services.checks_library import check_runnable    # noqa: E402
from bossman.services.module_library import CONTRACT_MARKDOWN  # noqa: E402

VALIDATOR = BOSSMAN / "bin" / "starlark-check"

# ── fixtures: known-good / known-bad artifacts ──────────────────────────────

GOOD_STAR = (
    'def main(ctx, params):\n'
    '    res = ctx.run(["cat", "/proc/loadavg"], mutates=False)\n'
    '    load1 = res.stdout.split(" ")[0]\n'
    '    return {"changed": False, "msg": "load " + load1, "data": {"state": "OK", "metrics": {}}}\n'
)
TRYEXCEPT_STAR = (
    'def main(ctx, params):\n'
    '    try:\n'
    '        x = 1\n'
    '    except:\n'
    '        x = 2\n'
    '    return {"changed": False, "msg": "x", "data": {}}\n'
)
CMK_STAR = (
    'def main(ctx, params):\n'
    '    res = ctx.run(["cmk", "--check"], mutates=False)\n'
    '    return {"changed": False, "msg": res.stdout, "data": {"state": "OK"}}\n'
)


class FakeChatClient:
    """Returns canned responses; records calls. Duck-types ChatClient for both
    complete_text (checks) and complete_json (templates/classify)."""

    def __init__(self, text: str | None = None, json_obj: dict | None = None):
        self._text = text
        self._json = json_obj
        self.calls = 0

    # NB: never a max_tokens cap — the model bounds output via its context size;
    # we just accept and ignore whatever kwargs the real interface passes.
    async def complete_text(self, messages, **_) -> str:
        self.calls += 1
        return self._text

    async def complete_json(self, messages, json_schema, schema_name, **_) -> dict:
        self.calls += 1
        return self._json


class FakeLib:
    """Stands in for the module library: canned source + real starlark-check."""

    def __init__(self, record: dict):
        self._record = record

    async def source(self, fqcn: str) -> dict:
        return self._record

    async def validate(self, star_code: str, params: dict | None = None) -> dict:
        proc = subprocess.run(
            [str(VALIDATOR), "-params", json.dumps(params or {}), "-"],
            input=star_code.encode(), capture_output=True, timeout=90,
        )
        try:
            return json.loads(proc.stdout.decode())
        except (ValueError, UnicodeDecodeError):
            return {"ok": False, "stub_ok": False, "errors": [{"message": proc.stderr.decode()[:200]}]}


def _record(name: str = "probe") -> dict:
    return {
        "fqcn": f"checkmk.{name}", "name": name, "collection": "checkmk",
        "short_description": "probe check", "doc": {}, "source_py": "def check(): pass",
    }


# ── template contract (batch_verify) ────────────────────────────────────────

def test_flat_schema_is_clean():
    schema = {
        "port": {"type": "number", "default": 80, "description": "p"},
        "hosts": {"type": "list", "default": [], "items": {
            "name": {"type": "string", "default": ""}, "ip": {"type": "string", "default": ""}}},
    }
    assert bv.verify_template_schema(schema) == []


@pytest.mark.parametrize("bad_default", [{"value": 80}, {}, {"ipv4": "0.0.0.0", "ipv6": "::"}])
def test_object_default_flagged(bad_default):
    problems = bv.verify_template_schema({"port": {"type": "number", "default": bad_default}})
    assert any("default is an object" in p for p in problems)


def test_noncanonical_type_flagged():
    problems = bv.verify_template_schema({"on": {"type": "boolean", "default": True}})
    assert any("non-canonical type 'boolean'" in p for p in problems)


def test_items_json_schema_nesting_flagged():
    schema = {"servers": {"type": "list", "default": [],
                          "items": {"type": "object", "properties": {"name": {"type": "string"}}}}}
    assert any("JSON-schema nesting" in p for p in bv.verify_template_schema(schema))


def test_warnings_do_not_gate_valid_template():
    # multi-var loop unpack + |default var must NOT be flagged as missing.
    template = "{% for key, value in env_vars %}{{ key }}={{ value }}\n{% endfor %}{{ extra | default('') }}"
    schema = {"env_vars": {"type": "list", "default": []}}
    assert bv.verify_template(template, schema) == []           # no hard errors
    assert not bv.warn_template(template, schema)                # and no false-positive warnings


def test_grammar_contract_forbids_object_default():
    # the source fix: the LLM output schema pins `default` to non-object types.
    spec = q._TEMPLATE_SCHEMA["properties"]["values_schema"]["additionalProperties"]["properties"]["default"]
    assert "object" not in spec["type"]
    assert set(spec["type"]) == {"string", "number", "boolean", "array", "null"}


def test_flatten_unwraps_value_default():
    schema = {"port": {"type": "number", "default": {"value": 402, "description": "std"}}}
    q._flatten_schema_defaults(schema)
    assert schema["port"]["default"] == 402


# ── template pipeline integration (mocked LLM → correct on disk) ─────────────

async def test_generate_template_writes_flat(tmp_path, monkeypatch):
    monkeypatch.setattr(q, "TEMPLATES_DIR", tmp_path)
    # LLM emits a wrapped {value} default; the write path must flatten it.
    chat = FakeChatClient(json_obj={
        "template": "port = {{ port }}\n",
        "values_schema": {"port": {"type": "number", "default": {"value": 402}, "description": "p"}},
        "sample_values": {"port": 402},
    })
    ok = await q._generate_template("probe", man_text="Port to listen on.", web_text="x" * 500, qwen=chat)
    assert ok
    written = json.loads((tmp_path / "probe" / "schema.json").read_text())
    assert written["port"]["default"] == 402                    # flattened
    assert bv.verify_template_schema(written) == []             # and contract-clean


# ── check translate pipeline (mocked LLM + real starlark-check) ──────────────

async def test_good_check_accepted_and_runnable():
    chat, lib = FakeChatClient(text=GOOD_STAR), FakeLib(_record())
    out = await translate_one(chat, lib, CONTRACT_MARKDOWN, "checkmk.probe",
                              max_attempts=1, build_messages=build_checkmk_messages)
    assert out.accepted and check_runnable(out.star_code)
    assert bv.verify_check(out.star_code, out.validation) == []


async def test_tryexcept_check_rejected():
    chat, lib = FakeChatClient(text=TRYEXCEPT_STAR), FakeLib(_record())
    out = await translate_one(chat, lib, CONTRACT_MARKDOWN, "checkmk.probe",
                              max_attempts=1, build_messages=build_checkmk_messages)
    assert not out.accepted
    assert bv.verify_check(out.star_code, out.validation)       # non-empty problems


async def test_cmk_wrapper_valid_but_not_runnable():
    chat, lib = FakeChatClient(text=CMK_STAR), FakeLib(_record())
    out = await translate_one(chat, lib, CONTRACT_MARKDOWN, "checkmk.probe",
                              max_attempts=1, build_messages=build_checkmk_messages)
    # parses fine, but wraps cmk → not runnable → verify_check flags it.
    assert not check_runnable(out.star_code)
    assert any("not runnable" in p for p in bv.verify_check(out.star_code, out.validation))


# ── UI execution qualification: snmp | local | service ───────────────────────

def test_execution_snmp_from_source():
    assert detect_check_execution(source_py="register.snmp_section(SNMPTree(...))", star_code="") == "snmp"


def test_execution_snmp_from_star():
    assert detect_check_execution(source_py="", star_code='ctx.run(["snmpwalk", "-v2c", host])') == "snmp"


def test_execution_local_default():
    assert detect_check_execution(source_py="register.agent_section(...)", star_code=GOOD_STAR) == "local"


async def test_execution_service_via_llm(monkeypatch):
    # snmp is deterministic (no model); local<->service is the LLM's call. Verify
    # classify_one returns the LLM's 'service' for a non-snmp check (fileinfo-style).
    import classify_check_execution as cce
    monkeypatch.setattr(cce, "_source_py", lambda name: "register.agent_section(...)")
    monkeypatch.setattr(cce, "_star", lambda name: "def main(ctx, params): pass")
    monkeypatch.setattr(cce, "_read_meta", lambda name: {"short_description": "monitor configured files",
                                                         "description": "fileinfo", "options": {}})
    chat = FakeChatClient(json_obj={"execution": "service", "confidence": "high"})
    assert await cce.classify_one(chat, "fileinfo") == "service"


async def test_execution_snmp_skips_model(monkeypatch):
    import classify_check_execution as cce
    monkeypatch.setattr(cce, "_source_py", lambda name: "SNMPTree(base='.1.3.6')")
    monkeypatch.setattr(cce, "_star", lambda name: "")
    chat = FakeChatClient(json_obj={"execution": "service"})   # would be wrong if used
    assert await cce.classify_one(chat, "if64") == "snmp"
    assert chat.calls == 0                                      # deterministic, no model call
