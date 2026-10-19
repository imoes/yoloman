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
    # Refused as soon as it is offered (the catalog records nginx.conf as this template's file) — named in
    # `conflicts`; before, the cross-source sweep withdrew it afterwards. Either way it must carry the reason.
    reasons = [w.get("reason") or "" for w in idx["withdrawn"] + idx["conflicts"]
               if w["path"] == "/etc/logrotate.d/nginx"]
    assert any("/etc/nginx/nginx.conf" in r for r in reasons), reasons


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


def test_a_role_template_is_not_bound_to_a_file_that_only_shares_its_name(tmp_path):
    """The catalog says which file a role's template renders. A codec binding by NAME to another file of the
    package (/etc/sysconfig/haproxy for the haproxy.cfg template) is refused, even when — as on RedHat — a
    family template holds the catalog path and only the name bindings are left."""
    cat, cod, tpl, ver = _fixture(
        tmp_path,
        {"haproxy": {"template": "haproxy", "families": {
            "debian": {"config_path": "/etc/haproxy/haproxy.cfg"},
            "redhat": {"config_path": "/etc/haproxy/haproxy.cfg"}}}},
        {"/etc/sysconfig/haproxy": {"codec": "keyvalue", "paths": ["/etc/sysconfig/haproxy"]},
         "/usr/local/etc/haproxy/haproxy.cfg": {"codec": "none", "paths": ["/usr/local/etc/haproxy/haproxy.cfg"]}},
        {"haproxy": "global\\n    maxconn {{ x }}\\n"})
    idx = build_template_index(cat, cod, tpl, "", ver)
    assert "/etc/sysconfig/haproxy" not in idx["paths"]
    refused = [c for c in idx["conflicts"] if c["path"] == "/etc/sysconfig/haproxy"]
    assert refused and "/etc/haproxy/haproxy.cfg" in refused[0]["reason"]


@pytest.mark.parametrize("family,path", [("redhat", "/etc/sysconfig/haproxy"), ("redhat", "/etc/logrotate.d/haproxy"),
                                         ("", "/etc/pam.d/cron"), ("", "/etc/default/cron"),
                                         ("redhat", "/etc/raddb/mods-available/redis")])
def test_the_real_corpus_binds_no_role_template_to_a_namesake(family, path):
    """Against the shipped catalogs, per family: each of these was bound to a role template of another file."""
    from bossman.tools._paths import configs_dir

    root = configs_dir(__file__)
    idx = build_template_index(root / "package_catalog.json", root / "config_codecs.json",
                               root / "config_templates", family, root / "config_path_verdicts.json")
    entry = idx["paths"].get(path)
    assert entry is None or entry["template"] not in ("haproxy", "cron", "redis"), \
        f"{path} is bound to the role template {entry['template']!r}"


def test_a_family_template_is_not_offered_to_another_family(tmp_path):
    """A `-redhat` template records the RPM's file. The Debian index must not offer it — named in `withdrawn`;
    an index built without a family keeps it, as before."""
    cat, cod, tpl, ver = _fixture(tmp_path, {}, {}, {"grep-redhat": "COLOR={{ x }}\n"})
    (tpl / "grep-redhat" / "meta.json").write_text(json.dumps(
        {"target_path": "/etc/GREP_COLORS", "family": "redhat", "witness": "rpm"}))
    deb = build_template_index(cat, cod, tpl, "debian", ver)
    assert "/etc/GREP_COLORS" not in deb["paths"]
    w = [x for x in deb["withdrawn"] if x["path"] == "/etc/GREP_COLORS"]
    assert w and w[0]["verdict"] == "other-family" and "redhat" in w[0]["reason"]
    assert build_template_index(cat, cod, tpl, "redhat", ver)["paths"]["/etc/GREP_COLORS"]["template"] == "grep-redhat"
    assert "/etc/GREP_COLORS" in build_template_index(cat, cod, tpl, "", ver)["paths"]


def test_the_real_debian_index_offers_no_redhat_template():
    from bossman.tools._paths import configs_dir

    root = configs_dir(__file__)
    idx = build_template_index(root / "package_catalog.json", root / "config_codecs.json",
                               root / "config_templates", "debian", root / "config_path_verdicts.json")
    foreign = [(p, e["template"]) for p, e in idx["paths"].items() if e.get("family") not in (None, "debian")]
    assert not foreign, foreign[:5]


def test_a_template_the_gate_refuses_is_named_not_dropped(tmp_path):
    cat, cod, tpl, ver = _fixture(tmp_path, {}, {}, {"x-redhat": "COLOR={{ x }}\n"})
    (tpl / "x-redhat" / "template.j2").write_text("")          # empty body: the gate refuses it
    (tpl / "x-redhat" / "meta.json").write_text(json.dumps({"target_path": "/etc/x.conf", "family": "redhat"}))
    idx = build_template_index(cat, cod, tpl, "redhat", ver)
    w = [x for x in idx["withdrawn"] if x["template"] == "x-redhat"]
    assert w and w[0]["verdict"] == "not-configurable" and w[0]["path"] == "/etc/x.conf"
    assert not [x for x in build_template_index(cat, cod, tpl, "debian", ver)["withdrawn"] if x["template"] == "x-redhat"]
