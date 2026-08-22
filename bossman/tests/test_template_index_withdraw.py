"""The withdrawal rule: a binding whose path the package does not ship must not be offered."""

import json

from bossman.services.template_index import build_template_index


def _fixture(tmp_path, verdicts):
    """A catalog with one template bound to /etc/thing, plus whatever verdicts the test wants."""
    templates = tmp_path / "config_templates"
    (templates / "thing").mkdir(parents=True)
    # A body with a variable, so the gate does not refuse it as an unparameterised text.
    (templates / "thing" / "template.j2").write_text("setting = {{ setting }}\n")
    (templates / "thing" / "schema.json").write_text(json.dumps({"setting": {"type": "string"}}))
    (templates / "thing" / "sample.json").write_text(json.dumps({"setting": "x"}))
    (templates / "thing" / "meta.json").write_text(json.dumps(
        {"target_path": "/etc/thing", "witness": "deb", "source": "deb"}))
    catalog = tmp_path / "package_catalog.json"
    catalog.write_text("{}")
    codecs = tmp_path / "config_codecs.json"
    codecs.write_text(json.dumps({"/etc/thing": {"codec": "none", "packages": ["thing"]}}))
    vpath = tmp_path / "config_path_verdicts.json"
    vpath.write_text(json.dumps(verdicts))
    return build_template_index(catalog, codecs, templates, "", vpath)


def test_a_directory_is_withdrawn_and_reported(tmp_path):
    r = _fixture(tmp_path, {"/etc/thing": {"verdict": "directory", "package": "thing",
                                           "postinst_mentions": False}})
    # Configure writes the WHOLE file. Offering it here would try to write over a directory.
    assert "/etc/thing" not in r["paths"]
    assert [w["path"] for w in r["withdrawn"]] == ["/etc/thing"]
    w = r["withdrawn"][0]
    # NOTHING VANISHES SILENTLY: the template, the verdict and the package all travel with the withdrawal,
    # so a screen can explain the absence instead of showing none.
    assert w["template"] == "thing" and w["verdict"] == "directory" and w["package"] == "thing"
    assert "no file at this path" in w["reason"]


def test_absent_without_a_maintainer_script_is_withdrawn(tmp_path):
    r = _fixture(tmp_path, {"/etc/thing": {"verdict": "absent", "package": "thing",
                                           "postinst_mentions": False}})
    assert "/etc/thing" not in r["paths"]
    assert len(r["withdrawn"]) == 1


def test_absent_but_created_at_install_is_kept(tmp_path):
    # Absent from the ARCHIVE is not absent from the host: a config the postinst writes exists on every
    # installed machine, and withdrawing it would remove a working editor.
    r = _fixture(tmp_path, {"/etc/thing": {"verdict": "absent", "package": "thing",
                                           "postinst_mentions": True}})
    assert r["paths"]["/etc/thing"]["template"] == "thing"
    assert r["withdrawn"] == []


def test_a_shipped_file_is_kept(tmp_path):
    r = _fixture(tmp_path, {"/etc/thing": {"verdict": "file", "package": "thing",
                                           "postinst_mentions": False}})
    assert r["paths"]["/etc/thing"]["template"] == "thing"
    assert r["withdrawn"] == []


def test_an_unmeasured_path_is_kept(tmp_path):
    # Absence of a measurement is not a measurement of absence. Withdrawing everything unproven would
    # remove thousands of working editors.
    r = _fixture(tmp_path, {})
    assert r["paths"]["/etc/thing"]["template"] == "thing"
    assert r["withdrawn"] == []
