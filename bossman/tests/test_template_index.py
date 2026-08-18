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
    for name in template_dirs:
        (tpl / name).mkdir(parents=True)
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


def test_unreadable_inputs_yield_an_empty_index_not_an_error(tmp_path):
    """No index means no Configure button — the safe direction. Raising here would take out the whole
    Configuration tab for a missing catalog file."""
    idx = build_template_index(tmp_path / "nope.json", tmp_path / "nope2.json", tmp_path / "nodir")
    assert idx == {"paths": {}, "conflicts": []}
