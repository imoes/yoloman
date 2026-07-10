"""Block G9 — the Checkmk-check translation helpers (pure, no LLM/IO)."""

import nestedtext

from bossman.services.checkmk_translation import (
    CHECK_CONTRACT_ADDENDUM,
    build_checkmk_messages,
    build_checkmk_metadata_nt,
)

_RECORD = {
    "fqcn": "checkmk.fileinfo",
    "name": "fileinfo",
    "collection": "checkmk",
    "short_description": "File %s",
    "doc": {
        "short_description": "File %s",
        "description": "Checkmk fileinfo check as an on-host Starlark module.",
        "options": {"path": {"type": "str", "required": True, "description": "file path"}},
    },
    "source_py": "def parse_fileinfo(string_table):\n    return string_table\n",
    "examples": "",
}


def test_metadata_is_readonly_check_nt():
    meta = nestedtext.loads(build_checkmk_metadata_nt(_RECORD), top="dict")
    assert meta["fqcn"] == "checkmk.fileinfo"
    assert meta["collection"] == "checkmk"
    # NestedText leaves are strings — writes is the string "False", kind "check"
    assert meta["writes"] == "False"        # a check never mutates
    assert meta["runtime"] == "starlark"
    assert meta["kind"] == "check"
    assert meta["source"] == "translated"
    assert meta["fqcn"] == f"{meta['collection']}.{meta['name']}"


def test_metadata_has_required_keys():
    meta = nestedtext.loads(build_checkmk_metadata_nt(_RECORD), top="dict")
    for key in ("name", "fqcn", "collection", "short_description", "options", "writes", "runtime"):
        assert key in meta, key


def test_messages_carry_contract_addendum_and_source():
    msgs = build_checkmk_messages("BASE-CONTRACT-MARKER", _RECORD)
    assert msgs[0]["role"] == "system" and msgs[1]["role"] == "user"
    system = msgs[0]["content"]
    # both the injected base language contract and the check addendum are present
    assert "BASE-CONTRACT-MARKER" in system
    assert CHECK_CONTRACT_ADDENDUM.split("\n", 1)[0] in system
    # read-only discipline is spelled out
    assert "READ-ONLY" in system
    # the source and fqcn reach the user turn
    assert "checkmk.fileinfo" in msgs[1]["content"]
    assert "parse_fileinfo" in msgs[1]["content"]


def test_messages_truncate_giant_source():
    big = dict(_RECORD, source_py="x = 1\n" * 20000)  # ~120k chars
    msgs = build_checkmk_messages("C", big)
    assert "(truncated)" in msgs[1]["content"]
