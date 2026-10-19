"""The RedHat side of the qualify pipeline and the helpers it shares with the Debian side.

No LLM, no docker, no network: what is pinned is the plumbing that decides WHICH file is a package's config,
WHICH template is offered for it, and whether a template IS that file — each a place where a plausible answer
was once the wrong one.
"""

import json

from bossman.tools import qualify_packages as Q
from bossman.tools.directive_coverage import active_keys, coverage
from bossman.tools.recover_template_targets import SCRIPT_DIR, score
from bossman.tools.template_invariants import mechanical, render_with_defaults, same_file


def test_the_pam_stack_never_beats_the_real_config_without_a_catalog_path():
    """openssh-server on EL9 declares /etc/pam.d/sshd AND /etc/ssh/sshd_config. With no catalog path (every
    RedHat universe package) both fell into the fallback tier, tied on depth, and the PAM file won on order —
    applying that template would replace sshd_config with a PAM stack."""
    declared = ["/etc/pam.d/sshd", "/etc/ssh/sshd_config", "/etc/sysconfig/sshd"]
    assert Q._pick_primary_config(declared, "", "openssh-server") == "/etc/ssh/sshd_config"


def test_a_sysconfig_snippet_is_still_chosen_when_it_is_all_there_is():
    """Last resort is not never: arpwatch ships only /etc/sysconfig/arpwatch on EL9, and that file IS its
    configuration there."""
    assert Q._pick_primary_config(["/etc/sysconfig/arpwatch"], "", "arpwatch") == "/etc/sysconfig/arpwatch"


def test_redhat_entries_are_keyed_by_suffixed_template_and_carry_the_package(monkeypatch, tmp_path):
    universe = {"redhat": {"chrony": {"config_paths": ["/etc/chrony.conf"], "desc": "NTP"}}}
    monkeypatch.setattr(Q, "UNIVERSE", tmp_path / "u.json")
    (tmp_path / "u.json").write_text(json.dumps(universe))
    catalog = {"chrony": {"template": "chrony", "families": {
        "redhat": {"packages": ["chrony"], "config_path": "/etc/chrony.conf"}}}}
    entries = Q.build_entry_map(catalog, "redhat")
    e = entries["chrony-redhat"]
    assert e["name"] == "chrony" and e["_family"] == "redhat"
    assert Q._fam(e)["config_path"] == "/etc/chrony.conf"
    assert Q._fam(e)["config_paths"] == ["/etc/chrony.conf"]


def test_the_debian_branch_stays_the_default():
    entry = {"families": {"debian": {"config_path": "/etc/a"}, "redhat": {"config_path": "/etc/b"}}}
    assert Q._fam(entry)["config_path"] == "/etc/a"
    assert Q._fam({**entry, "_family": "redhat"})["config_path"] == "/etc/b"


def _template(tmp_path, body, schema, sample=None):
    d = tmp_path / "tpl"
    d.mkdir()
    (d / "template.j2").write_text(body)
    (d / "schema.json").write_text(json.dumps(schema))
    (d / "sample.json").write_text(json.dumps(sample or {}))
    return d


def test_ansible_filters_render_and_a_null_default_does_not_override_the_template_fallback(tmp_path):
    """Enriched templates use `| bool` and `| dict2items` and fall back with `| default(...)`. Plain jinja2
    called them broken; passing a null default as None made `{% for %}` raise. Both were renderer defects,
    not template defects."""
    d = _template(tmp_path,
                  "{% if enabled | bool %}on{% endif %}\n{% for k in extra | default({}) | dict2items %}{{ k.key }}{% endfor %}\n",
                  {"enabled": {"type": "bool", "default": "yes"}, "extra": {"type": "object", "default": None}})
    assert render_with_defaults(d).strip() == "on"


def test_a_template_reproducing_the_shipped_file_passes_the_invariants(tmp_path):
    shipped = "# chrony\nserver pool.ntp.org iburst\ndriftfile /var/lib/chrony/drift\n"
    d = _template(tmp_path, "# chrony\nserver {{ ntp_server }} iburst\ndriftfile /var/lib/chrony/drift\n",
                  {"ntp_server": {"type": "string", "default": "pool.ntp.org"}}, {"ntp_server": "time.example.org"})
    result = mechanical(d, shipped)
    assert result["ok"], result
    assert same_file(render_with_defaults(d), shipped)


def test_an_invented_line_fails_the_invariants(tmp_path):
    shipped = "server pool.ntp.org\n"
    d = _template(tmp_path, "server {{ s }}\nmakestep 1 3\n", {"s": {"type": "string", "default": "pool.ntp.org"}},
                  {"s": "time.example.org"})
    result = mechanical(d, shipped)
    assert not result["ok"] and result["invented_lines"] == 1


def test_target_recovery_scores_by_lines_and_refuses_scripts():
    assert score("a\nb\nc\n", "a\nb\nc\n") == 1.0
    assert score("a\nb\n", "c\nd\n") == 0.0
    assert SCRIPT_DIR.match("/etc/init.d/acpi-fakekey")
    assert SCRIPT_DIR.match("/etc/cron.daily/logrotate")
    assert not SCRIPT_DIR.match("/etc/cron.d/backup")       # a crontab fragment IS config
    assert not SCRIPT_DIR.match("/etc/default/grub")


def test_directive_coverage_counts_the_files_own_keys_case_insensitively():
    text = "# c\nPermitRootLogin no\nPort 22\n"
    assert active_keys(text, " ") == {"PermitRootLogin", "Port"}
    cov = coverage(text, {"permitrootlogin": {}, "LogLevel": {}}, " ")
    assert cov == {"keys": 2, "covered": 1, "extra": 1}
