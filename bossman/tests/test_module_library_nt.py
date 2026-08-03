"""The module library reads metadata sidecars, preferring .yaml over a legacy .nt, and coerces the schema's
booleans (which arrive as all-strings from NestedText).
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


def test_metadata_path_prefers_yaml_over_legacy_nt(tmp_path):
    """The .yaml is the ORIGINAL; the .nt files in configs/modules.d were generated from them by an additive
    pass, and NestedText is all-strings — so preferring .nt read `true` as "true" and `8080` as "8080" for
    modules whose argspec really had a bool and an int. The .nt is only a fallback now, for a tree that has
    not been converted."""
    base = tmp_path / "posix"
    base.mkdir()
    (base / "acl.nt").write_text("name: acl\n")
    assert metadata_path(tmp_path, "posix.acl").name == "acl.nt"      # only the .nt exists
    (base / "acl.yaml").write_text("name: acl\n")
    assert metadata_path(tmp_path, "posix.acl").name == "acl.yaml"    # the original wins
