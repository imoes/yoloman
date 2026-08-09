"""yolo-man CLI: lint/show/convert are pure (no DB) and are covered here; `run` drives the real engine and is
exercised live. Playbooks are YAML — the NestedText surface these fixtures used is gone.
"""

from bossman.cli import main

PLAYBOOK = """\
name: cli_demo
description: A tiny demo playbook.
params:
  pkg:
    type: string
    required: true
steps:
  - name: install
    loop:
      - curl
      - git
    apt:
      name: "{{ item }}"
      state: present
"""


def test_lint_ok(tmp_path, capsys):
    f = tmp_path / "demo.yaml"
    f.write_text(PLAYBOOK)
    assert main(["lint", str(f)]) == 0
    assert "OK: cli_demo" in capsys.readouterr().out


def test_lint_reports_invalid(tmp_path, capsys):
    f = tmp_path / "bad.yaml"
    f.write_text("description: no name\n")
    assert main(["lint", str(f)]) == 1
    assert "INVALID" in capsys.readouterr().err


def test_show_lists_steps_and_loop(tmp_path, capsys):
    f = tmp_path / "demo.yaml"
    f.write_text(PLAYBOOK)
    assert main(["show", str(f)]) == 0
    out = capsys.readouterr().out
    assert "chunk main" in out
    assert "install [apt]" in out
    assert "loop=" in out


def test_convert_yaml_to_json_and_back_roundtrips_structure(tmp_path, capsys):
    # YAML in → JSON out → parses to the same plan structure. A file mode is the interesting value: it must
    # stay the string "0755" and not be re-read as an octal or decimal number on the way back.
    yaml_src = tmp_path / "p.yaml"
    yaml_src.write_text(
        "name: conv\n"
        "steps:\n"
        "  - name: s1\n"
        "    file:\n"
        "      path: /tmp/x\n"
        "      mode: '0755'\n"
    )
    json_out = tmp_path / "p.json"
    assert main(["convert", str(yaml_src), str(json_out)]) == 0
    assert json_out.exists()
    assert main(["lint", str(json_out)]) == 0
    assert '"0755"' in json_out.read_text()

    # And back to YAML.
    yaml_back = tmp_path / "back.yaml"
    assert main(["convert", str(json_out), str(yaml_back)]) == 0
    assert main(["lint", str(yaml_back)]) == 0


# Runbooks are Ansible task syntax.
RUNBOOK_YAML = """\
name: web baseline
targets: group:web-servers
tasks:
  - name: show hostname
    shell: echo {{ inventory_hostname }}
  - name: ensure nginx
    apt:
      name: nginx
      state: present
    when: ansible_distribution == "Debian"
"""

# A role: the same task syntax under a `role:` key.
ROLE_YAML = """\
role: base
tasks:
  - name: touch
    file:
      path: /tmp/x
      state: touch
"""


def test_runbook_lint_ok(tmp_path, capsys):
    f = tmp_path / "rb.yaml"
    f.write_text(RUNBOOK_YAML)
    assert main(["runbook", "lint", str(f)]) == 0
    out = capsys.readouterr().out
    assert "OK: runbook 'web baseline'" in out
    assert "2 step(s)" in out


def test_runbook_lint_recognizes_role(tmp_path, capsys):
    f = tmp_path / "role.yaml"
    f.write_text(ROLE_YAML)
    assert main(["runbook", "lint", str(f)]) == 0
    assert "OK: role 'base'" in capsys.readouterr().out


def test_runbook_lint_reports_invalid(tmp_path, capsys):
    f = tmp_path / "bad.yaml"
    f.write_text("name: broken\ntasks:\n  - notastep\n")
    assert main(["runbook", "lint", str(f)]) == 1
    assert "INVALID" in capsys.readouterr().err
