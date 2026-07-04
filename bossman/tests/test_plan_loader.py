"""Unit tests for bossman.services.plan_loader — pure parsing/resolution
logic, no DB, no network. Mirrors internal/tasks/task_test.go's coverage
shape on the Go side (parse errors, param resolution, substitution) since
this module is deliberately kept syntax-compatible with it.
"""

import pytest

from bossman.services.plan_loader import (
    PlanError,
    load_host_vars,
    load_plans_dir,
    parse_plan,
    resolve_params,
    substitute,
)


def _write(tmp_path, name, content):
    path = tmp_path / name
    path.write_text(content)
    return path


MODULE_PLAN = """
name: deploy_motd
description: "set the motd"
params:
  message: { type: string, required: true }
steps:
  - name: write_motd
    ansible.builtin.copy:
      dest: /etc/motd
      content: "{{ message }}"
"""


def test_parse_plan_module_step(tmp_path):
    path = _write(tmp_path, "deploy_motd.yaml", MODULE_PLAN)
    plan = parse_plan(path.read_bytes(), path)

    assert plan.name == "deploy_motd"
    assert len(plan.steps) == 1
    step = plan.steps[0]
    assert step.kind == "module"
    assert step.module == "copy"
    assert step.body == {"dest": "/etc/motd", "content": "{{ message }}"}
    assert step.check_mode is False
    assert step.on_failure == "abort"


PIPELINE_PLAN = """
name: count_procs
steps:
  - name: count
    pipeline:
      - ["ps", "aux"]
      - ["wc", "-l"]
"""


def test_parse_plan_pipeline_step(tmp_path):
    path = _write(tmp_path, "p.yaml", PIPELINE_PLAN)
    plan = parse_plan(path.read_bytes(), path)

    step = plan.steps[0]
    assert step.kind == "pipeline"
    assert step.pipeline == [["ps", "aux"], ["wc", "-l"]]


UPLOAD_PLAN = """
name: deploy_conf
params:
  vhost_name: { type: string, required: true }
steps:
  - name: upload_it
    upload:
      local_path: "files/deploy_conf/{{ vhost_name }}.conf.tmpl"
      remote_name: "{{ vhost_name }}.conf"
  - name: place_it
    check_mode: true
    on_failure: continue
    ansible.builtin.copy:
      src: "/var/lib/agentic-mcp/uploads/{{ vhost_name }}.conf"
      dest: "/etc/nginx/sites-available/{{ vhost_name }}.conf"
"""


def test_parse_plan_upload_step_and_step_flags(tmp_path):
    path = _write(tmp_path, "deploy_conf.yaml", UPLOAD_PLAN)
    plan = parse_plan(path.read_bytes(), path)

    upload_step, module_step = plan.steps
    assert upload_step.kind == "upload"
    assert upload_step.upload_local_path == "files/deploy_conf/{{ vhost_name }}.conf.tmpl"
    assert upload_step.upload_remote_name == "{{ vhost_name }}.conf"

    assert module_step.check_mode is True
    assert module_step.on_failure == "continue"


@pytest.mark.parametrize(
    "content,message",
    [
        ("description: x\nsteps: []", "missing required 'name'"),
        ("name: x\nsteps: []", "'steps' must be a non-empty list"),
        ("name: x", "'steps' must be a non-empty list"),
        (
            "name: x\nsteps:\n  - name: s\n    ansible.builtin.copy: {}\n    ansible.builtin.file: {}",
            "multiple ansible.builtin",
        ),
        ("name: x\nsteps:\n  - name: s\n    bogus_key: {}", "unexpected key"),
        (
            "name: x\nsteps:\n  - name: s\n    on_failure: retry\n    ansible.builtin.copy: {}",
            "on_failure must be",
        ),
        ("name: x\nsteps:\n  - {}", "missing required 'name'"),
    ],
)
def test_parse_plan_errors(tmp_path, content, message):
    path = _write(tmp_path, "bad.yaml", content)
    with pytest.raises(PlanError, match=message):
        parse_plan(path.read_bytes(), path)


def test_load_plans_dir_sorted_and_duplicate_detection(tmp_path):
    _write(tmp_path, "b_plan.yaml", "name: b\nsteps:\n  - name: s\n    ansible.builtin.copy: {}")
    _write(tmp_path, "a_plan.yaml", "name: a\nsteps:\n  - name: s\n    ansible.builtin.copy: {}")

    plans = load_plans_dir(tmp_path)
    assert [p.name for p in plans] == ["a", "b"]


def test_load_plans_dir_duplicate_name_errors(tmp_path):
    _write(tmp_path, "one.yaml", "name: dup\nsteps:\n  - name: s\n    ansible.builtin.copy: {}")
    _write(tmp_path, "two.yaml", "name: dup\nsteps:\n  - name: s\n    ansible.builtin.copy: {}")

    with pytest.raises(PlanError, match="duplicate plan name"):
        load_plans_dir(tmp_path)


def test_load_plans_dir_missing_directory_returns_empty(tmp_path):
    assert load_plans_dir(tmp_path / "nonexistent") == []


def test_load_host_vars_missing_file_returns_empty(tmp_path):
    assert load_host_vars(tmp_path, "web01.example.com") == {}


def test_load_host_vars_loads_file(tmp_path):
    host_vars_dir = tmp_path / "host_vars"
    host_vars_dir.mkdir()
    (host_vars_dir / "web01.example.com.yaml").write_text("server_name: web01.internal\n")

    assert load_host_vars(tmp_path, "web01.example.com") == {"server_name": "web01.internal"}


def test_resolve_params_precedence_default_then_host_vars_then_explicit(tmp_path):
    path = _write(
        tmp_path,
        "p.yaml",
        "name: p\nparams:\n"
        "  a: { type: string, default: from_default }\n"
        "  b: { type: string, default: from_default }\n"
        "  c: { type: string, default: from_default }\n"
        "steps:\n  - name: s\n    ansible.builtin.copy: {}\n",
    )
    plan = parse_plan(path.read_bytes(), path)

    args = resolve_params(plan, host_vars={"b": "from_host_vars", "c": "from_host_vars"}, explicit={"c": "from_explicit"})

    assert args == {"a": "from_default", "b": "from_host_vars", "c": "from_explicit"}


def test_resolve_params_missing_required_raises(tmp_path):
    path = _write(tmp_path, "p.yaml", "name: p\nparams:\n  a: { required: true }\nsteps:\n  - name: s\n    ansible.builtin.copy: {}\n")
    plan = parse_plan(path.read_bytes(), path)

    with pytest.raises(PlanError, match="missing required parameter"):
        resolve_params(plan, host_vars={}, explicit={})


def test_resolve_params_pattern_mismatch_raises(tmp_path):
    path = _write(
        tmp_path,
        "p.yaml",
        "name: p\nparams:\n  a: { pattern: '^[a-z]+$' }\nsteps:\n  - name: s\n    ansible.builtin.copy: {}\n",
    )
    plan = parse_plan(path.read_bytes(), path)

    with pytest.raises(PlanError, match="does not match required pattern"):
        resolve_params(plan, host_vars={}, explicit={"a": "NOT-LOWER"})


def test_resolve_params_unknown_param_raises(tmp_path):
    path = _write(tmp_path, "p.yaml", "name: p\nsteps:\n  - name: s\n    ansible.builtin.copy: {}\n")
    plan = parse_plan(path.read_bytes(), path)

    with pytest.raises(PlanError, match="unknown parameter"):
        resolve_params(plan, host_vars={}, explicit={"surprise": "value"})


def test_resolve_params_wrong_type_raises(tmp_path):
    path = _write(
        tmp_path, "p.yaml", "name: p\nparams:\n  n: { type: number }\nsteps:\n  - name: s\n    ansible.builtin.copy: {}\n"
    )
    plan = parse_plan(path.read_bytes(), path)

    with pytest.raises(PlanError, match="expected number"):
        resolve_params(plan, host_vars={}, explicit={"n": "not-a-number"})


def test_substitute_whole_placeholder_preserves_type():
    assert substitute("{{ port }}", {"port": 443}) == 443
    assert substitute("{{ enabled }}", {"enabled": True}) is True


def test_substitute_embedded_placeholder_stringifies():
    assert substitute("port={{ port }}", {"port": 443}) == "port=443"


def test_substitute_nested_dict_and_list():
    result = substitute({"a": ["{{ x }}", "literal"], "b": {"c": "{{ y }}"}}, {"x": "X", "y": "Y"})
    assert result == {"a": ["X", "literal"], "b": {"c": "Y"}}


def test_substitute_unresolved_reference_raises():
    with pytest.raises(PlanError, match="unresolved parameter reference"):
        substitute("{{ missing }}", {})


def test_plan_version_is_sha256_hex_and_changes_with_content(tmp_path):
    path = _write(tmp_path, "p.yaml", "name: p\nsteps:\n  - name: s\n    ansible.builtin.copy: {}\n")
    plan = parse_plan(path.read_bytes(), path)
    v1 = plan.version()
    assert len(v1) == 64
    int(v1, 16)  # must be valid hex

    path.write_text("name: p\nsteps:\n  - name: s\n    ansible.builtin.file: {}\n")
    plan2 = parse_plan(path.read_bytes(), path)
    assert plan2.version() != v1
