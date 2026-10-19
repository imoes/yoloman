"""explain_differs: `wrong-file` — a template that writes none of its file's settings renders another file."""

from bossman.tools import explain_differs as E


def test_a_template_with_none_of_the_files_settings_is_wrong_file():
    # Measured: ssh_config (Host, AddressFamily) generated for /etc/default/ssh, whose settings are SSHD_OPTS.
    wf = E.wrong_file("Host *\n    AddressFamily any\n", "# Default settings for openssh-server.\nSSHD_OPTS=\n")
    assert wf
    assert wf and "another file" in wf["reason"]


def test_a_setting_the_file_only_documents_as_a_comment_counts():
    # `#Port 22` names the setting: a template that activates it configures THIS file.
    assert E.wrong_file("Port 2222\n", "#Port 22\n#ListenAddress 0.0.0.0\n") is None


def test_partial_overlap_is_a_differing_template_not_a_wrong_file():
    assert E.wrong_file("Port 22\nBogus yes\n", "Port 22\n") is None


def test_a_file_of_comments_alone_is_not_judged():
    # EL's dhcpd.conf ships "see dhcpd.conf(5)": a correct template adds settings the file cannot name.
    assert E.wrong_file("default-lease-time 600;\n", "#\n# DHCP Server Configuration file.\n#   see dhcpd.conf(5)\n") is None


def test_a_template_that_writes_no_setting_is_not_judged():
    assert E.wrong_file("# only comments\n", "Port 22\n") is None


def test_a_wrong_file_reason_outlives_its_unit_until_the_template_changes(tmp_path, monkeypatch):
    # The index withdraws the binding, so stage 5 stops reaching it; dropping the reason then would let the next
    # index build bind it again. It stays while the template is unchanged.
    (tmp_path / "t").mkdir()
    (tmp_path / "t" / "template.j2").write_text("Host *\n")
    monkeypatch.setattr(E.F, "TEMPLATES", tmp_path)
    entry = {"template": "t", "category": "wrong-file", "template_sha": E.template_sha("t")}
    assert E.keep("debian|t|/etc/x", entry, units={})
    (tmp_path / "t" / "template.j2").write_text("Port {{ port }}\n")
    assert not E.keep("debian|t|/etc/x", entry, units={})
