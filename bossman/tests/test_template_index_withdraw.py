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


def test_a_file_that_exists_elsewhere_is_not_withdrawn(tmp_path):
    # The measurement ran on Debian. "Absent from this package on this distro" is not "no such file":
    # /etc/named.conf is absent from Debian's bind9 (Debian puts it in /etc/bind/) and present on EL.
    # 51 of 494 real-config-path absences are of this kind — withdrawing them would remove editors for files
    # that are on every host.
    r = _fixture(tmp_path, {"/etc/thing": {"verdict": "absent", "package": "thing",
                                           "postinst_mentions": False, "exists_elsewhere": True}})
    assert r["paths"]["/etc/thing"]["template"] == "thing"
    assert r["withdrawn"] == []


def test_a_file_no_package_owns_is_not_withdrawn(tmp_path):
    # /etc/hostname, /etc/fstab, /etc/passwd: created by the installer or the base system, owned by no
    # package, and therefore "absent" from every archive. Measured by asking the package manager itself
    # (find_unowned_base_files.py: 34 of debian:12's 106 /etc files). Without this guard the withdrawal
    # removed the editor for the machine's own hostname.
    (tmp_path / "config_unowned_paths.json").write_text(json.dumps(
        {"/etc/thing": {"families": ["debian"], "container_artifact": False, "note": "system-created"}}))
    r = _fixture(tmp_path, {"/etc/thing": {"verdict": "absent", "package": "thing",
                                           "postinst_mentions": False, "exists_elsewhere": False}})
    assert r["paths"]["/etc/thing"]["template"] == "thing"
    assert r["withdrawn"] == []


def test_a_container_artifact_does_not_earn_the_exemption(tmp_path):
    # A file that exists only in the container image (docker-clean, /etc/BUILDTIME) is real in THAT image and
    # is no evidence that an installed system creates it. Recorded rather than filtered out, so the
    # distinction is visible — and it must not act as an exemption.
    (tmp_path / "config_unowned_paths.json").write_text(json.dumps(
        {"/etc/thing": {"families": ["debian"], "container_artifact": True, "note": "container only"}}))
    r = _fixture(tmp_path, {"/etc/thing": {"verdict": "absent", "package": "thing",
                                           "postinst_mentions": False, "exists_elsewhere": False}})
    assert "/etc/thing" not in r["paths"]
    assert len(r["withdrawn"]) == 1
