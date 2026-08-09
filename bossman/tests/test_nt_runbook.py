"""The canonical runbook/role document validator (services/nt_runbook.parse_data).

These feed the canonical document shape directly — the form the DB stores and the Ansible parser emits —
because that is what this validator's job is: catch a malformed document whether it came from a parser or
straight out of the database. The Ansible *syntax* is covered in test_ansible_playbook.py.
"""

import pytest

from bossman.services.nt_runbook import NTRunbookError, Role, Runbook, parse_data

_RUNBOOK = {
    "name": "web baseline",
    "targets": "group:web-servers",
    "steps": [
        {"name": "install nginx", "module": "apt", "args": {"name": "nginx", "state": "present"}},
        {"name": "reload if changed", "module": "service", "args": {"name": "nginx", "state": "reloaded"},
         "when": "dropped_config.changed", "register": "reloaded_nginx"},
        {"name": "rebuild font cache", "run": "fc-cache -f"},
    ],
}

_ROLE = {
    "role": "mysql_server",
    "description": "A MySQL database server.",
    "parameters": {"mysql_port": 3306},
    "steps": [{"name": "install", "module": "apt", "args": {"name": "mysql-server", "state": "present"}}],
    "monitoring": {"checks": ["mysql", "disk"]},
    "notifications": {"routes": ["dba-oncall"]},
}


def test_parse_runbook():
    rb = parse_data(_RUNBOOK)
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
    role = parse_data(_ROLE)
    assert isinstance(role, Role) and role.kind == "role"
    assert role.name == "mysql_server"
    assert role.parameters == {"mysql_port": 3306}
    assert role.checks == ["mysql", "disk"]
    assert role.notification_routes == ["dba-oncall"]
    assert role.steps[0].module == "apt"


def test_run_and_module_conflict_errors():
    with pytest.raises(NTRunbookError):
        parse_data({"name": "x", "steps": [{"run": "echo hi", "module": "command", "args": {"cmd": "echo"}}]})


def test_step_without_module_errors():
    with pytest.raises(NTRunbookError):
        parse_data({"name": "x", "steps": [{"name": "no module", "args": {"a": "b"}}]})


def test_unknown_step_key_errors():
    # `notify` used to be the example here, but notify IS a known step key (see _STEP_KEYS) — the test only
    # passed because _str_list refused a scalar, i.e. it was asserting the wrong thing. Ansible's scalar
    # shorthand `notify: restart nginx` is now accepted, so use a key that really is unknown.
    with pytest.raises(NTRunbookError) as exc:
        parse_data({"name": "x", "steps": [{"module": "ping", "nofity": "someone"}]})
    assert "nofity" in str(exc.value)


def test_runbook_needs_name():
    with pytest.raises(NTRunbookError):
        parse_data({"steps": [{"module": "ping"}]})


def test_empty_steps_errors():
    with pytest.raises(NTRunbookError):
        parse_data({"name": "x", "steps": None})


def test_loop_list_parsed():
    rb = parse_data({"name": "x", "steps": [
        {"module": "user", "loop": ["alice", "bob"], "args": {"name": "{{ item }}"}}]})
    assert rb.steps[0].loop == ["alice", "bob"]


def test_a_stored_document_round_trips_through_the_validator():
    """to_dict() output must validate again. The engine, scheduler and rollout all re-validate a doc loaded
    from the database, so a document this code emits and then refuses would break every stored runbook."""
    assert parse_data(parse_data(_RUNBOOK).to_dict()).to_dict() == parse_data(_RUNBOOK).to_dict()
    assert parse_data(parse_data(_ROLE).to_dict()).kind == "role"
