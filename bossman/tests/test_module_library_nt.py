"""Block NT-5: the module library reads NestedText metadata sidecars,
preferring .nt over .yaml, and coerces the schema's booleans (which arrive
as all-strings from NestedText).
"""

from bossman.services.module_library import load_metadata, metadata_path


def test_load_metadata_nt_coerces_booleans(tmp_path):
    nt = tmp_path / "m.nt"
    nt.write_text(
        "name: x\n"
        "writes: false\n"
        "options:\n"
        "    force:\n"
        "        type: bool\n"
        "        required: true\n"
    )
    meta = load_metadata(nt)
    # writes must be the bool False, NOT the truthy string "false".
    assert meta["writes"] is False
    assert meta["options"]["force"]["required"] is True
    # non-boolean scalars stay strings (NestedText semantics).
    assert meta["options"]["force"]["type"] == "bool"


def test_load_metadata_yaml_still_works(tmp_path):
    y = tmp_path / "m.yaml"
    y.write_text("name: x\nwrites: true\n")
    assert load_metadata(y)["writes"] is True


def test_metadata_path_prefers_nt_over_yaml(tmp_path):
    base = tmp_path / "ansible.posix"
    base.mkdir()
    (base / "acl.yaml").write_text("name: acl\n")
    assert metadata_path(tmp_path, "ansible.posix.acl").name == "acl.yaml"
    (base / "acl.nt").write_text("name: acl\n")
    assert metadata_path(tmp_path, "ansible.posix.acl").name == "acl.nt"
