"""The module library reads YAML metadata sidecars and coerces the schema's booleans.

This file used to be about preferring `.yaml` over a legacy `.nt`. NestedText is gone
(docs/nestedtext-removal.md) and so is the preference — but the boolean COERCION stayed, and the reason is
worth keeping in a test: a sidecar written by hand can carry `writes: "false"` as a string, and
`bool("false")` is True. That is the difference between a read-only module and one that writes.
"""

from bossman.services.module_library import load_metadata, metadata_path


def test_load_metadata_yaml(tmp_path):
    y = tmp_path / "m.yaml"
    y.write_text("name: x\nwrites: true\n")
    assert load_metadata(y)["writes"] is True


def test_a_string_boolean_is_coerced(tmp_path):
    y = tmp_path / "m.yaml"
    y.write_text('name: x\nwrites: "false"\noptions:\n  force:\n    type: bool\n    required: "true"\n')
    meta = load_metadata(y)
    assert meta["writes"] is False              # NOT the truthy string "false"
    assert meta["options"]["force"]["required"] is True
    assert meta["options"]["force"]["type"] == "bool"   # non-booleans stay as they are


def test_metadata_path_is_the_yaml(tmp_path):
    assert metadata_path(tmp_path, "posix.acl").name == "acl.yaml"
