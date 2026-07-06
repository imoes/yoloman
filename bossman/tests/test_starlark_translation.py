"""Tests for services/starlark_translation.py — the pure prompt/metadata
helpers of the Block-G8 pipeline. No network, no subprocess."""

import yaml

from bossman.services import module_library, starlark_translation

RECORD = {
    "fqcn": "ansible.posix.sysctl",
    "collection": "ansible.posix",
    "name": "sysctl",
    "short_description": "Manage entries in sysctl.conf.",
    "doc": {
        "description": ["This module manipulates sysctl entries."],
        "options": {
            "name": {"type": "str", "required": True, "description": ["The dot-separated path."], "aliases": ["key"]},
            "value": {"type": "str", "description": "Desired value"},
            "state": {"type": "str", "choices": ["present", "absent"], "default": "present"},
            "reload": {"type": "bool", "default": True},
        },
    },
    "examples": "- ansible.posix.sysctl:\n    name: vm.swappiness\n    value: '5'\n",
    "source_py": "def main():\n    pass\n" * 3,
}


def test_build_metadata_yaml_is_valid_and_parseable_by_library():
    meta_yaml = starlark_translation.build_metadata_yaml(RECORD)
    meta = module_library.parse_metadata(meta_yaml)  # the same gate submit_module uses
    assert meta["fqcn"] == "ansible.posix.sysctl"
    assert meta["writes"] is True
    assert meta["options"]["name"]["required"] is True
    assert meta["options"]["state"]["choices"] == ["present", "absent"]
    assert meta["options"]["name"]["aliases"] == ["key"]


def test_build_metadata_yaml_info_module_is_readonly():
    record = dict(RECORD, fqcn="community.docker.docker_container_info", name="docker_container_info", collection="community.docker")
    meta = yaml.safe_load(starlark_translation.build_metadata_yaml(record))
    assert meta["writes"] is False


def test_sample_params_covers_required_options_only():
    params = starlark_translation.sample_params(RECORD)
    assert params == {"name": "example"}
    # choices win over the type dummy
    record = dict(RECORD)
    record["doc"] = {"options": {"state": {"type": "str", "required": True, "choices": ["present", "absent"]}}}
    assert starlark_translation.sample_params(record) == {"state": "present"}


def test_translation_messages_embed_contract_and_source():
    msgs = starlark_translation.build_translation_messages("THE-CONTRACT", RECORD)
    assert msgs[0]["role"] == "system"
    assert "THE-CONTRACT" in msgs[0]["content"]
    assert "ansible.posix.sysctl" in msgs[1]["content"]
    assert "```python" in msgs[1]["content"]


def test_translation_messages_truncate_huge_sources():
    record = dict(RECORD, source_py="x" * 200_000)
    msgs = starlark_translation.build_translation_messages("C", record)
    assert "(truncated)" in msgs[1]["content"]
    # bounded near SOURCE_CHAR_BUDGET (+ argspec/prose overhead), not the full 200k
    assert len(msgs[1]["content"]) < starlark_translation.SOURCE_CHAR_BUDGET + 12_000


def test_normalize_rewrites_is_operator():
    assert starlark_translation.normalize_starlark("if x is None:") == "if x == None:"
    assert starlark_translation.normalize_starlark("if x is not None:") == "if x != None:"
    assert starlark_translation.normalize_starlark("if a is True and b is not False:") == "if a == True and b != False:"
    # a variable merely containing "is" is untouched
    assert starlark_translation.normalize_starlark("is_linux = True") == "is_linux = True"
    # extract_star_code applies it end-to-end
    got = starlark_translation.extract_star_code("def main(ctx, params):\n    return params.get('x') is not None\n")
    assert "!= None" in got and " is not " not in got


def test_extract_star_code_handles_fences_and_bare():
    bare = "def main(ctx, params):\n    return {}\n"
    assert starlark_translation.extract_star_code(bare) == bare
    fenced = "Here you go:\n```python\ndef main(ctx, params):\n    return {}\n```\nDone."
    assert starlark_translation.extract_star_code(fenced) == "def main(ctx, params):\n    return {}\n"
    starlark_fence = "```starlark\ndef main(ctx, params):\n    return {}\n```"
    assert starlark_translation.extract_star_code(starlark_fence) == "def main(ctx, params):\n    return {}\n"
    untagged = "```\ndef main(ctx, params):\n    return {}\n```"
    assert starlark_translation.extract_star_code(untagged) == "def main(ctx, params):\n    return {}\n"


def test_retry_messages_append_findings():
    base = starlark_translation.build_translation_messages("C", RECORD)
    retry = starlark_translation.build_retry_messages(base, "def main(ctx, params): pass", {"errors": [{"stage": "lint", "message": "boom"}]})
    assert len(retry) == len(base) + 2
    assert retry[-2]["role"] == "assistant"
    assert "boom" in retry[-1]["content"]


def test_hints_target_the_is_operator_and_friends():
    hints = starlark_translation.hints_for({"errors": [{"stage": "parse", "message": "stdin.star:5:16: got is, want ':'"}]})
    assert any("is`/`is not`" in h or "`is`" in h for h in hints)
    # A retry for an `is` parse error carries the targeted fix inline.
    retry = starlark_translation.build_retry_messages(
        [], "code", {"errors": [{"stage": "parse", "message": "got is, want ':'"}]}
    )
    assert "== None" in retry[-1]["content"]
    # No hint for an unrecognized error → no "Most likely fix" block.
    assert not starlark_translation.hints_for({"errors": [{"stage": "lint", "message": "totally novel"}]})
