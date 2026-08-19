"""build_template_index — "which template renders THIS file", pinned to the bug it replaced.

The basename heuristic it supersedes (host-detail.component.ts: path basename minus .conf, matched
against template dir names) is not merely crude — it was measurably wrong on real data:
/etc/aardvark-dns/aardvark-dns.conf resolved to the template dir `aardvark-dns`, which renders
/etc/aardvark-dns/forward.conf. The write path is template_render, whole file and no merge, so the
"Edit via template" button would have written one file's content over another. The first test below is
exactly that case.
"""

import json
from pathlib import Path

from bossman.services.template_index import build_template_index


def _fixture(tmp_path: Path, catalog: dict, codecs: dict, template_dirs: list[str]) -> tuple:
    (tmp_path / "package_catalog.json").write_text(json.dumps(catalog))
    (tmp_path / "config_codecs.json").write_text(json.dumps(codecs))
    tpl = tmp_path / "config_templates"
    tpl.mkdir()  # always, so a caller can add dirs itself after the fixture returns
    for name in template_dirs:
        (tpl / name).mkdir()
    return tmp_path / "package_catalog.json", tmp_path / "config_codecs.json", tpl


def _role(template: str, config_path: str) -> dict:
    return {"template": template, "families": {"debian": {"config_path": config_path}}}


def test_the_aardvark_case_resolves_by_path_not_by_name(tmp_path):
    """Two template dirs of the same package, each rendering a DIFFERENT file. A basename match picks
    the one whose name looks like the path; the index picks the one whose declared path IS the path."""
    cat, cod, tpl = _fixture(
        tmp_path,
        {"aardvark-dns": _role("aardvark_dns", "/etc/aardvark-dns/aardvark-dns.conf")},
        {"forward.conf": {"packages": ["aardvark-dns"], "paths": ["/etc/aardvark-dns/forward.conf"]}},
        ["aardvark_dns", "aardvark-dns", "forward.conf"],
    )
    idx = build_template_index(cat, cod, tpl)
    assert idx["paths"]["/etc/aardvark-dns/aardvark-dns.conf"]["template"] == "aardvark_dns"
    assert idx["paths"]["/etc/aardvark-dns/forward.conf"]["template"] == "forward.conf"


def test_an_unknown_path_is_absent_so_the_ui_offers_nothing(tmp_path):
    """Absence is the point. No entry → no Configure button; refusing with a reason beats rendering the
    wrong file, which is what a name-similarity fallback would do."""
    cat, cod, tpl = _fixture(tmp_path, {}, {}, [])
    assert build_template_index(cat, cod, tpl)["paths"] == {}


def test_the_catalog_wins_over_the_codec_registry_and_the_loss_is_reported(tmp_path):
    """Measured 20 times on the real data, e.g. /etc/haproxy/haproxy.cfg where the role offers
    `haproxy` and the codec key offers `haproxy.cfg` — and BOTH dirs exist. The catalog wins because it
    is the curated side and the only one the withdrawal rule has been applied to, but the other
    candidate is reported: a resolution nobody can see is indistinguishable from a coincidence."""
    cat, cod, tpl = _fixture(
        tmp_path,
        {"haproxy": _role("haproxy", "/etc/haproxy/haproxy.cfg")},
        {"haproxy.cfg": {"packages": ["haproxy"], "paths": ["/etc/haproxy/haproxy.cfg"]}},
        ["haproxy", "haproxy.cfg"],
    )
    idx = build_template_index(cat, cod, tpl)
    assert idx["paths"]["/etc/haproxy/haproxy.cfg"] == {
        "template": "haproxy", "source": "catalog", "role": "haproxy"}
    assert idx["conflicts"] == [{"path": "/etc/haproxy/haproxy.cfg", "chosen": "haproxy",
                                "chosen_source": "catalog", "also": "haproxy.cfg",
                                "also_source": "codec"}]


def test_a_template_dir_that_does_not_exist_is_not_indexed(tmp_path):
    """The catalog may name a template that was never generated. Indexing it would offer an editor for
    a template the server cannot serve."""
    cat, cod, tpl = _fixture(tmp_path, {"ghost": _role("ghost", "/etc/ghost.conf")}, {}, [])
    assert build_template_index(cat, cod, tpl)["paths"] == {}


def test_a_withdrawn_template_is_not_indexed(tmp_path):
    """`template: null` is how the catalog records "this template does not configure its own file"
    (sshd's template was /etc/pam.d/sshd aimed at sshd_config — applying it locks you out). The index
    must not resurrect what that rule withdrew."""
    cat, cod, tpl = _fixture(
        tmp_path, {"openssh-server": _role(None, "/etc/ssh/sshd_config")}, {}, ["openssh-server"])
    assert build_template_index(cat, cod, tpl)["paths"] == {}


def test_glob_paths_are_excluded_from_both_sources(tmp_path):
    """"/etc/php/*/fpm/pool.d/www.conf" identifies a SET of files. One template for a set answers a
    question nobody asked, and the UI looks up a concrete path."""
    cat, cod, tpl = _fixture(
        tmp_path,
        {"php-fpm": _role("php-fpm", "/etc/php/*/fpm/pool.d/www.conf")},
        {"my.cnf": {"packages": ["mysql"], "paths": ["/etc/mysql/conf.d/*", "/etc/mysql/my.cnf"]}},
        ["php-fpm", "my.cnf"],
    )
    idx = build_template_index(cat, cod, tpl)
    assert list(idx["paths"]) == ["/etc/mysql/my.cnf"]


def test_a_refused_template_is_not_indexed_from_the_codec_side_either(tmp_path):
    """Source 2 had no gate at all: 437 of 3488 codec-sourced paths pointed at a template the gate
    refuses — shell scripts, ufw profiles, unparameterised texts — each offering "Edit via template" on
    a file whose Apply writes a fixed text over the live config. /etc/X11/Xsession was one."""
    cat, cod, tpl = _fixture(tmp_path, {}, {"Xsession": {"paths": ["/etc/X11/Xsession"]}}, [])
    (tpl / "Xsession").mkdir()
    (tpl / "Xsession" / "template.j2").write_text("#!/bin/sh\nexec x-session-manager\n")
    (tpl / "Xsession" / "schema.json").write_text(json.dumps({"session": {}, "opts": {}, "tty": {}}))
    assert build_template_index(cat, cod, tpl)["paths"] == {}


def test_the_result_is_cached_and_the_cache_key_is_not_shadowed(tmp_path):
    """Gating reads 5460 template bodies (548 ms), so the result is cached — and the second call must
    actually HIT. It did not at first: the codec loop reused the name `key`, so the result was stored
    under the last codec entry's name. Only the timing showed it, which is why this asserts the object
    IDENTITY rather than mere equality."""
    cat, cod, tpl = _fixture(
        tmp_path,
        {"nginx": _role("nginx", "/etc/nginx/nginx.conf")},
        {"a.conf": {"paths": ["/etc/a.conf"]}, "z.conf": {"paths": ["/etc/z.conf"]}},
        ["nginx", "a.conf", "z.conf"],
    )
    first = build_template_index(cat, cod, tpl)
    assert build_template_index(cat, cod, tpl) is first


def test_unreadable_inputs_yield_an_empty_index_not_an_error(tmp_path):
    """No index means no Configure button — the safe direction. Raising here would take out the whole
    Configuration tab for a missing catalog file."""
    idx = build_template_index(tmp_path / "nope.json", tmp_path / "nope2.json", tmp_path / "nodir")
    assert idx == {"paths": {}, "conflicts": []}


def _tpl(dirpath, name, body="x = {{ a }}\ny = {{ b }}\nz = {{ c }}\n",
         fields=("a", "b", "c"), meta=None):
    """A template dir that PASSES the gate (three placed fields), optionally with meta.json."""
    d = dirpath / name
    d.mkdir(exist_ok=True)
    (d / "template.j2").write_text(body)
    (d / "schema.json").write_text(json.dumps({f: {} for f in fields}))
    if meta is not None:
        (d / "meta.json").write_text(json.dumps(meta))
    return name


def test_a_recorded_target_path_makes_a_package_named_template_reachable(tmp_path):
    """Source 3, and the reason it exists: a template dir named after the PACKAGE cannot be found by an
    index that resolves by FILE. Measured before this: 2786 of 5460 dirs were unreachable, 2071 of them
    because no codec key's basename matched their name — including this shape."""
    cat, cod, tpl = _fixture(tmp_path, {}, {}, [])
    _tpl(tpl, "avahi_daemon", meta={"target_path": "/etc/avahi/avahi-daemon.conf"})
    idx = build_template_index(cat, cod, tpl)
    assert idx["paths"]["/etc/avahi/avahi-daemon.conf"] == {
        "template": "avahi_daemon", "source": "template-meta"}


def test_an_ambiguous_template_records_its_rivals_and_is_NOT_indexed(tmp_path):
    """21 ejabberd module templates all resolve to one ejabberd.yml, and 190 paths are claimed by 509
    templates. The backfill records `ambiguous_with` and no target_path precisely so the index skips them:
    choosing among ten by name length would be inventing an answer and hiding the question."""
    cat, cod, tpl = _fixture(tmp_path, {}, {}, [])
    _tpl(tpl, "ceph_mds", meta={"ambiguous_with": ["ceph", "ceph_osd"],
                                "candidate_path": "/etc/ceph/ceph.conf"})
    assert build_template_index(cat, cod, tpl)["paths"] == {}


def test_the_recorded_target_yields_to_the_curated_sources_and_says_so(tmp_path):
    """Precedence: catalog, then codec registry (where the template's name and the file's basename agree
    by construction), then the recorded target. The loser is reported rather than dropped — 296 paths are
    claimed by both a file-named and a package-named template, and which of those two is BETTER is a
    question about content that precedence cannot settle."""
    cat, cod, tpl = _fixture(tmp_path, {}, {"avahi-daemon.conf": {"paths": ["/etc/avahi/avahi-daemon.conf"]}}, [])
    _tpl(tpl, "avahi-daemon.conf")
    _tpl(tpl, "avahi_daemon", meta={"target_path": "/etc/avahi/avahi-daemon.conf"})
    idx = build_template_index(cat, cod, tpl)
    assert idx["paths"]["/etc/avahi/avahi-daemon.conf"]["template"] == "avahi-daemon.conf"
    assert idx["conflicts"] == [{"path": "/etc/avahi/avahi-daemon.conf", "chosen": "avahi-daemon.conf",
                                "chosen_source": "codec", "also": "avahi_daemon",
                                "also_source": "template-meta"}]


def test_a_recorded_directory_target_is_refused_like_any_other(tmp_path):
    cat, cod, tpl = _fixture(tmp_path, {}, {}, [])
    _tpl(tpl, "evolution_data_server", meta={"target_path": "/etc/evolution-data-server/"})
    assert build_template_index(cat, cod, tpl)["paths"] == {}


def test_a_directory_is_never_a_render_target(tmp_path):
    """FOUND BY AUDITING MY OWN INVARIANTS. /etc/bind sat in the index as a config target while
    /etc/bind/named.conf lay right beside it in the same registry — and template_render writes one FILE, so
    a directory is unwritable, not merely odd. Detectable without a filesystem: something else is known to
    live under it."""
    cat, cod, tpl = _fixture(tmp_path, {}, {
        "bind": {"paths": ["/etc/bind"]},
        "named.conf": {"paths": ["/etc/bind/named.conf"]},
    }, [])
    _tpl(tpl, "bind")
    _tpl(tpl, "named.conf")
    idx = build_template_index(cat, cod, tpl)
    assert "/etc/bind" not in idx["paths"]
    assert idx["paths"]["/etc/bind/named.conf"]["template"] == "named.conf"


def test_an_ancillary_path_is_still_indexed(tmp_path):
    """The other half, and my first fix got it wrong: excluding /etc/default/… cost 626 paths their editor.
    ANCILLARY_DIRS answers "which file is this PACKAGE's main config" (main_config_path), not "which
    template renders THIS file". /etc/default/chrony is a real file with a template that renders exactly
    it."""
    cat, cod, tpl = _fixture(tmp_path, {}, {"chrony": {"paths": ["/etc/default/chrony"]}}, [])
    _tpl(tpl, "chrony")
    assert build_template_index(cat, cod, tpl)["paths"]["/etc/default/chrony"]["template"] == "chrony"
