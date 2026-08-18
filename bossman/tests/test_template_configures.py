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
    body = "#!/usr/sbin/nft -f\nflush ruleset\ntable inet filter {\n}\n# hook policy priority chain\n"
    name = tpl("nftables.conf", body,
               {"flush": {}, "table": {}, "hook": {}, "policy": {}, "priority": {}, "chain": {}})
    assert bpc._template_configures(name) is True


def test_a_rich_schema_describing_another_file_is_refused(tpl):
    """sshd: 90 sshd_config field names, body is /etc/pam.d/sshd. Not one field appears."""
    name = tpl("sshd", "@include common-auth\n@include common-account\n",
               {f"field_{i}": {} for i in range(90)})
    assert bpc._template_configures(name) is False


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
