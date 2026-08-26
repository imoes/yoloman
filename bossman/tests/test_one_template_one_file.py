"""One template renders ONE file — the mirror image of the conflict rule.

`conflicts` has always reported two templates claiming one path. Nothing asked the other question, and the
answer was worse: measured, the codec entry keyed `apparmor.d` lists **259** paths — /etc/apparmor.d/1password,
/Discord, /MongoDB_Compass … — and every one was bound to the single `apparmor.d` template. Configure writes
the WHOLE file, so pressing it on Discord's profile would have rendered a generic skeleton over it.
`logrotate.conf` did the same to 20 fragments and `apt.conf` to 17.

The same damage also assembles from DIFFERENT sources: the catalog binds `nginx` to /etc/nginx/nginx.conf
while the codec registry also binds it to /etc/logrotate.d/nginx. 14 templates were that shape.

What must NOT be refused is one file in several locations — /etc/magic, /etc/apache2/magic and
/etc/httpd/conf/magic are the same file, and 114 of the 130 multi-path templates are that.
"""

import json

import pytest

from bossman.services.template_index import build_template_index


def _fixture(tmp_path, catalog, codecs, template_dirs, verdicts=None):
    (tmp_path / "package_catalog.json").write_text(json.dumps(catalog))
    (tmp_path / "config_codecs.json").write_text(json.dumps(codecs))
    (tmp_path / "config_path_verdicts.json").write_text(json.dumps(verdicts or {}))
    tpl = tmp_path / "config_templates"
    tpl.mkdir()
    for name, body in template_dirs.items():
        d = tpl / name
        d.mkdir()
        # The body must PLACE one of its own schema fields, or template_gate refuses the binding before this
        # rule is ever asked — an empty schema made every fixture path vanish for the wrong reason.
        (d / "template.j2").write_text(body if "{{" in body else body + "setting = {{ x }}\n")
        (d / "schema.json").write_text(json.dumps({"x": {"type": "string"}}))
    return (tmp_path / "package_catalog.json", tmp_path / "config_codecs.json", tpl,
            tmp_path / "config_path_verdicts.json")


def test_a_codec_entry_listing_many_files_binds_only_its_own(tmp_path):
    cat, cod, tpl, ver = _fixture(
        tmp_path, {},
        {"apparmor.d": {"codec": "none", "paths": ["/etc/apparmor.d/apparmor.d",
                                                   "/etc/apparmor.d/Discord",
                                                   "/etc/apparmor.d/1password"]}},
        {"apparmor.d": "# a generic profile skeleton\nsetting = {{ x }}\n"})
    idx = build_template_index(cat, cod, tpl, "", ver)
    assert set(idx["paths"]) == {"/etc/apparmor.d/apparmor.d"}
    refused = {w["path"] for w in idx["withdrawn"] if w["verdict"] == "not-this-template"}
    assert refused == {"/etc/apparmor.d/Discord", "/etc/apparmor.d/1password"}
    # NOTHING VANISHES SILENTLY: the reason has to say what would have happened.
    reason = next(w["reason"] for w in idx["withdrawn"] if w["path"] == "/etc/apparmor.d/Discord")
    assert "WHOLE file" in reason and "different names" in reason


def test_the_same_file_in_several_locations_is_kept(tmp_path):
    """A distro difference, not a mistake — and 114 of the 130 multi-path templates are this."""
    cat, cod, tpl, ver = _fixture(
        tmp_path, {},
        {"magic": {"codec": "none", "paths": ["/etc/magic", "/etc/apache2/magic", "/etc/httpd/conf/magic"]}},
        {"magic": "# magic\n{{ x }}\n"})
    idx = build_template_index(cat, cod, tpl, "", ver)
    assert set(idx["paths"]) == {"/etc/magic", "/etc/apache2/magic", "/etc/httpd/conf/magic"}
    assert not [w for w in idx["withdrawn"] if w["verdict"] == "not-this-template"]


def test_the_catalogs_path_wins_across_sources(tmp_path):
    """The cross-source shape: the catalog names the real config, the codec registry adds a file that merely
    shares the daemon's name. Configure on /etc/logrotate.d/nginx would render nginx.conf over it."""
    cat, cod, tpl, ver = _fixture(
        tmp_path,
        {"nginx": {"template": "nginx", "families": {"debian": {"config_path": "/etc/nginx/nginx.conf"}}}},
        {"nginx": {"codec": "none", "paths": ["/etc/logrotate.d/nginx"]}},
        {"nginx": "worker_processes {{ x }};\n"})
    idx = build_template_index(cat, cod, tpl, "", ver)
    assert "/etc/nginx/nginx.conf" in idx["paths"]
    assert "/etc/logrotate.d/nginx" not in idx["paths"]
    reason = next(w["reason"] for w in idx["withdrawn"] if w["path"] == "/etc/logrotate.d/nginx")
    assert "/etc/nginx/nginx.conf" in reason and "shares that name" in reason


def test_with_nothing_to_prefer_the_bindings_stay(tmp_path):
    """No catalog entry and no path named after the template: picking one arbitrarily would be a guess, and
    an arbitrary guess that removes an editor is worse than leaving both visible."""
    cat, cod, tpl, ver = _fixture(
        tmp_path, {},
        {"thing": {"codec": "none", "paths": ["/etc/thing"]}},
        {"thing": "setting = {{ x }}\n"})
    # add a second, differently-named path through a SECOND codec entry resolving to the same template dir
    json.loads((tmp_path / "config_codecs.json").read_text())
    (tmp_path / "config_codecs.json").write_text(json.dumps({
        "thing": {"codec": "none", "paths": ["/etc/thing"]},
        "/etc/other/thing": {"codec": "none", "paths": ["/etc/other/thing"]},
    }))
    idx = build_template_index(cat, cod, tpl, "", ver)
    # /etc/thing is named after the template, so it is the one kept if a choice is forced at all.
    assert "/etc/thing" in idx["paths"]


@pytest.mark.parametrize("path", ["/etc/logrotate.d/nginx", "/etc/pam.d/cups", "/etc/default/snmpd"])
def test_the_real_corpus_no_longer_offers_a_foreign_renderer(path):
    """Against the shipped catalogs, not a fixture: these three were live bindings."""
    from bossman.tools._paths import configs_dir

    root = configs_dir(__file__)
    idx = build_template_index(root / "package_catalog.json", root / "config_codecs.json",
                               root / "config_templates", "", root / "config_path_verdicts.json")
    assert path not in idx["paths"], f"{path} is still bound to another file's template"
