"""Block G11 step 1 — NT runbook/role parser."""

import pytest

from bossman.services.nt_runbook import NTRunbookError, Role, Runbook, parse_document

_RUNBOOK = """\
name: web baseline
targets: group:web-servers
steps:
  -
    name: install nginx
    module: apt
    args:
      name: nginx
      state: present
  -
    name: reload if changed
    module: service
    args:
      name: nginx
      state: reloaded
    when: dropped_config.changed
    register: reloaded_nginx
  -
    name: rebuild font cache
    run: fc-cache -f
"""

_ROLE = """\
role: mysql_server
description: A MySQL database server.
parameters:
  mysql_port: 3306
steps:
  -
    name: install
    module: apt
    args:
      name: mysql-server
      state: present
monitoring:
  checks:
    - mysql
    - disk
notifications:
  routes:
    - dba-oncall
"""


def test_parse_runbook():
    rb = parse_document(_RUNBOOK)
    assert isinstance(rb, Runbook) and rb.kind == "runbook"
    assert rb.name == "web baseline" and rb.targets == "group:web-servers"
    assert [s.name for s in rb.steps] == ["install nginx", "reload if changed", "rebuild font cache"]
    # when / register captured
    s2 = rb.steps[1]
    assert s2.when == "dropped_config.changed" and s2.register == "reloaded_nginx"
    # run: shorthand -> shell module with args.cmd
    s3 = rb.steps[2]
    assert s3.module == "shell" and s3.args == {"cmd": "fc-cache -f"}


def test_parse_role_bundles_monitoring():
    role = parse_document(_ROLE)
    assert isinstance(role, Role) and role.kind == "role"
    assert role.name == "mysql_server"
    assert role.parameters == {"mysql_port": "3306"}   # NT leaves are strings
    assert role.checks == ["mysql", "disk"]
    assert role.notification_routes == ["dba-oncall"]
    assert role.steps[0].module == "apt"


def test_run_and_module_conflict_errors():
    with pytest.raises(NTRunbookError):
        parse_document("name: x\nsteps:\n  -\n    run: echo hi\n    module: command\n    args: {cmd: echo}\n")


def test_step_without_module_errors():
    with pytest.raises(NTRunbookError):
        parse_document("name: x\nsteps:\n  -\n    name: no module\n    args: {a: b}\n")


def test_unknown_step_key_errors():
    # `notify` used to be the example here, but notify IS a known step key (see _STEP_KEYS) — the test only
    # passed because _str_list refused a scalar, i.e. it was asserting the wrong thing. Ansible's scalar
    # shorthand `notify: restart nginx` is now accepted, so use a key that really is unknown.
    with pytest.raises(NTRunbookError) as exc:
        parse_document("name: x\nsteps:\n  -\n    module: ping\n    nofity: someone\n")
    assert "nofity" in str(exc.value)


def test_runbook_needs_name():
    with pytest.raises(NTRunbookError):
        parse_document("steps:\n  -\n    module: ping\n")


def test_empty_steps_errors():
    with pytest.raises(NTRunbookError):
        parse_document("name: x\nsteps:\n")


def test_loop_list_parsed():
    rb = parse_document(
        "name: x\nsteps:\n  -\n    module: user\n    loop:\n      - alice\n      - bob\n    args:\n      name: ${item}\n"
    )
    assert rb.steps[0].loop == ["alice", "bob"]
