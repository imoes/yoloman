"""yolo-man CLI (Block NT-4): lint/show/convert are pure (no DB) and are
covered here; `run` drives the real engine and is exercised live.
"""

from bossman.cli import main

NT_PLAYBOOK = """\
name: cli_demo
description:
    > A tiny demo playbook.
params:
    pkg:
        type: string
        required: true
steps:
    -
        name: install
        loop:
            - curl
            - git
        apt:
            name: {item}
            state: present
"""


def test_lint_ok(tmp_path, capsys):
    f = tmp_path / "demo.nt"
    f.write_text(NT_PLAYBOOK)
    assert main(["lint", str(f)]) == 0
    assert "OK: cli_demo" in capsys.readouterr().out


def test_lint_reports_invalid(tmp_path, capsys):
    f = tmp_path / "bad.nt"
    f.write_text("description: no name\n")
    assert main(["lint", str(f)]) == 1
    assert "INVALID" in capsys.readouterr().err


def test_show_lists_steps_and_loop(tmp_path, capsys):
    f = tmp_path / "demo.nt"
    f.write_text(NT_PLAYBOOK)
    assert main(["show", str(f)]) == 0
    out = capsys.readouterr().out
    assert "chunk main" in out
    assert "install [apt]" in out
    assert "loop=" in out


def test_convert_yaml_to_nt_and_back_roundtrips_structure(tmp_path, capsys):
    # YAML in → NestedText out → parses to the same plan structure.
    yaml_src = tmp_path / "p.yaml"
    yaml_src.write_text(
        "name: conv\n"
        "steps:\n"
        "  - name: s1\n"
        "    file:\n"
        "      path: /tmp/x\n"
        "      mode: '0755'\n"
    )
    nt_out = tmp_path / "p.nt"
    assert main(["convert", str(yaml_src), str(nt_out)]) == 0
    assert nt_out.exists()

    # The converted NestedText lints cleanly and preserves the unquoted mode.
    assert main(["lint", str(nt_out)]) == 0
    assert "mode: 0755" in nt_out.read_text()

    # And back to YAML.
    yaml_back = tmp_path / "back.yaml"
    assert main(["convert", str(nt_out), str(yaml_back)]) == 0
    assert main(["lint", str(yaml_back)]) == 0


RUNBOOK_NT = """\
name: web baseline
targets: group:web-servers
steps:
  -
    name: show hostname
    run: echo ${inventory_hostname}
  -
    name: ensure nginx
    module: apt
    args:
      name: nginx
      state: present
    when: ansible_distribution == "Debian"
"""

ROLE_NT = """\
role: base
steps:
  -
    name: touch
    module: file
    args:
      path: /tmp/x
      state: touch
"""


def test_runbook_lint_ok(tmp_path, capsys):
    f = tmp_path / "rb.nt"
    f.write_text(RUNBOOK_NT)
    assert main(["runbook", "lint", str(f)]) == 0
    out = capsys.readouterr().out
    assert "OK: runbook 'web baseline'" in out
    assert "2 step(s)" in out


def test_runbook_lint_recognizes_role(tmp_path, capsys):
    f = tmp_path / "role.nt"
    f.write_text(ROLE_NT)
    assert main(["runbook", "lint", str(f)]) == 0
    assert "OK: role 'base'" in capsys.readouterr().out


def test_runbook_lint_reports_invalid(tmp_path, capsys):
    f = tmp_path / "bad.nt"
    f.write_text("name: broken\nsteps:\n  - notastep\n")
    assert main(["runbook", "lint", str(f)]) == 1
    assert "INVALID" in capsys.readouterr().err
