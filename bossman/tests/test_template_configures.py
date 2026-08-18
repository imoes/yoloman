"""_template_configures — the gate that decides whether Configure is offered at all.

Configure's write path is template_render: WHOLE FILE, to the role's config_path. So a template that
does not configure that file does not merely look odd — applying it REPLACES a live config. Every case
below is a template that actually exists in configs/config_templates/.

The rule is deliberately ASYMMETRIC and the tests say so: what says "no" is broader than what says
"yes". A wrongly-withheld editor costs a click; a wrongly-offered one costs the host.
"""

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import build_package_catalog as bpc  # noqa: E402


@pytest.fixture()
def tpl(tmp_path, monkeypatch):
    """Write a template dir and point the module at it."""
    monkeypatch.setattr(bpc, "TEMPLATES_DIR", tmp_path)

    def _make(name: str, body: str, fields: dict) -> str:
        d = tmp_path / name
        d.mkdir()
        (d / "template.j2").write_text(body)
        (d / "schema.json").write_text(json.dumps(fields))
        return name

    return _make


def test_a_ufw_application_profile_is_refused(tpl):
    """THE openssh-server CASE. The template is a ufw profile; the role's config_path was
    /etc/ssh/sshd_config. Rendering five lines of firewall profile over the SSH daemon config locks
    everyone out — and the field test PASSED it, because the schema's single field is `port` and the
    profile has a ports= line."""
    name = tpl("openssh-server",
               "[OpenSSH]\ntitle=Secure shell server\ndescription=OpenSSH\nports=22/tcp\n",
               {"port": {"type": "int"}})
    assert bpc._template_configures(name) is False


def test_an_executable_is_refused_whatever_its_schema_says(tpl):
    name = tpl("spamassassin", "#!/bin/sh\n# start the daemon\nexit 0\n", {"pidfile": {"type": "str"}})
    assert bpc._template_configures(name) is False


def test_a_config_that_legitimately_has_a_shebang_is_not_refused(tpl):
    """/etc/nftables.conf really does run `#!/usr/sbin/nft -f`. Flagging it would disable a working
    editor, which is the mistake the whole rule is trying not to make."""
    body = ("#!/usr/sbin/nft -f\nflush ruleset\ntable {{ table }} filter {\n"
            "  chain {{ chain }} { policy {{ policy }}; priority {{ priority }} }\n}\n")
    name = tpl("nftables.conf", body,
               {"table": {}, "chain": {}, "policy": {}, "priority": {}})
    assert bpc._template_configures(name) is True


def test_a_rich_schema_describing_another_file_is_refused(tpl):
    """sshd: 90 sshd_config field names, body is /etc/pam.d/sshd. Not one field appears."""
    name = tpl("sshd", "@include common-auth\n@include common-account\n",
               {f"field_{i}": {} for i in range(90)})
    assert bpc._template_configures(name) is False


def test_naming_a_field_in_a_comment_is_not_placing_it(tpl):
    """THE CONVENTION THAT DISARMED THE OLD TEST. Templates are now self-documenting: every setting is
    preceded by a comment naming it. Under "does the name appear anywhere", the DOCUMENTATION satisfies
    the test — which is how squid passed while rendering the shipped example squid.conf with no
    placeholders at all (15 fields, 0 placed), and how opendkim passed while rendering a file that says
    of itself "not used by the opendkim systemd service".

    Pressing Apply on such a form writes a fixed text over the live config: the editor cannot express
    the user's input at all, whatever file it targets."""
    body = ("# http_port: the port Squid listens on\n"
            "# cache_dir: where objects are stored\n"
            "# maximum_object_size: the cap\n"
            "http_port 3128\ncache_dir ufs /var/spool/squid 100 16 256\n")
    name = tpl("squid", body, {"http_port": {}, "cache_dir": {}, "maximum_object_size": {}})
    assert bpc._template_configures(name) is False


def test_placing_one_field_is_enough_to_pass_and_that_is_a_known_limit(tpl):
    """chrony: it PLACES 1 of its 12 fields, so it passes — while rendering /etc/default/chrony against
    a config_path of /etc/chrony/chrony.conf. A template can be parameterised and still describe the
    wrong file, which this rule cannot see. That case is handled where it belongs, as a curated
    TEMPLATE_ALIAS entry (chrony → chrony.conf), and this test exists so the limit is written down
    rather than rediscovered."""
    body = "# DAEMON_OPTS: options passed at startup\nDAEMON_OPTS=\"{{ daemon_opts }}\"\n"
    name = tpl("chrony", body, {"daemon_opts": {}, **{f"directive_{i}": {} for i in range(11)}})
    assert bpc._template_configures(name) is True


def test_a_pass_on_a_tiny_schema_is_unknown_and_not_a_yes(tpl):
    """The asymmetry. One field appearing in the text is a coincidence, not evidence — `port` occurs in
    a ufw profile, an init script, almost any file. Measured: 19 of 89 catalog roles have a schema this
    small and every one of them "passed". None leaves the editor alone WITHOUT claiming it is correct."""
    name = tpl("memcached", "# listen port\n-p {{ port }}\n", {"port": {"type": "int"}})
    assert bpc._template_configures(name) is None


def test_a_pass_on_a_real_schema_is_a_yes(tpl):
    body = "Port {{ port }}\nPermitRootLogin {{ permit_root_login }}\nListenAddress {{ listen_address }}\n"
    name = tpl("sshd_config", body,
               {"port": {}, "permit_root_login": {}, "listen_address": {}, "ciphers": {}})
    assert bpc._template_configures(name) is True


def test_a_missing_template_dir_is_unknown_not_a_refusal(tmp_path, monkeypatch):
    """An unknown must not silently withdraw a working Configure — the caller distinguishes None from
    False precisely so "we cannot judge" and "we judged it bad" stay different states."""
    monkeypatch.setattr(bpc, "TEMPLATES_DIR", tmp_path)
    assert bpc._template_configures("never-generated") is None


def test_an_empty_schema_is_a_no_not_an_unknown(tpl):
    """A template with zero fields cannot express any input, so Apply renders a CONSTANT file over
    whatever the host has — the ufw-profile damage without the clue. Measured: 169 templates have an
    empty schema and 84 of them were REACHABLE, offering an editor with nothing to edit. Two catalog
    roles lost their Configure to this (dovecot, pure-ftpd), correctly: there was nothing to configure."""
    name = tpl("passt", "# passt configuration\n--bridge\n", {})
    assert bpc._template_configures(name) is False


def test_a_missing_schema_stays_an_unknown(tmp_path, monkeypatch):
    """The distinction that makes the rule above safe: "we cannot judge this" is not "there is nothing
    here to configure". A dir without schema.json is unjudgeable, and an unknown must not withdraw a
    working editor."""
    monkeypatch.setattr(bpc, "TEMPLATES_DIR", tmp_path)
    d = tmp_path / "half-written"
    d.mkdir()
    (d / "template.j2").write_text("Port {{ port }}\n")
    assert bpc._template_configures("half-written") is None


def test_a_section_qualified_field_is_the_same_directive(tpl):
    """THE COMPARISON THAT COST A ROLLBACK. An ini template qualifies its fields by section, so
    `server.host_name` IS the catalog's `host-name` under [server] — and the settings editor flattens
    nested values with exactly that dot. Comparing whole strings, the correctly repaired avahi-daemon
    template shared "nothing" with the 41 known directives of /etc/avahi/avahi-daemon.conf and was
    reverted as a failed repair; comparing last segments, 3 of its 4 fields match."""
    from bossman.services.template_gate import describes_file, directive_key
    assert directive_key("server.host_name") == "host_name"
    assert directive_key("host-name") == "host_name"
    assert describes_file({"server.host_name", "reflector.enabled"},
                          ["host-name", "domain-name", "enable-reflector"]) is True


def test_no_overlap_at_all_is_still_a_refusal(tpl):
    """The other side: the rule must keep rejecting a template that describes a different file. 240
    resolved targets were refused on this basis (arc_datadelivery claiming datadelivery.conf, whose 17
    real directives it shares none of)."""
    from bossman.services.template_gate import describes_file
    assert describes_file({"listen_port", "worker_count"}, ["bantime", "findtime", "maxretry"]) is False


def test_nothing_to_compare_against_is_not_a_verdict(tpl):
    """A path with no mined directives cannot be judged, and meta.json records witness: "none" rather
    than pretending it passed — 324 of the recorded targets are in that state."""
    from bossman.services.template_gate import describes_file
    assert describes_file({"a", "b"}, []) is None
    assert describes_file(set(), ["a"]) is None
