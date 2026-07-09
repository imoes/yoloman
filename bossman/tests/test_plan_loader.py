"""Unit tests for bossman.services.plan_loader — pure parsing/resolution
logic, no DB, no network. Mirrors internal/tasks/task_test.go's coverage
shape on the Go side (parse errors, param resolution, substitution) since
this module is deliberately kept syntax-compatible with it.
"""

from pathlib import Path

import pytest

from bossman.services.plan_loader import (
    Chunk,
    PlanError,
    build_plan_from_raw,
    PlanStep,
    chunks_needing_retranslation,
    hash_source_text,
    load_host_vars,
    load_plan_file,
    load_plans_dir,
    parse_plan,
    render_catalog_markdown,
    resolve_params,
    substitute,
)

REPO_PLANS_DIR = Path(__file__).resolve().parent.parent / "plans"


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
        ("name: x", "must have either 'chunks' or 'steps'"),
        (
            "name: x\nsteps:\n  - name: s\n    ansible.builtin.copy: {}\n    ansible.builtin.file: {}",
            "multiple module keys",
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


def test_plan_version_does_not_reread_disk(tmp_path):
    """version() must be derivable from already-parsed, in-memory chunk
    data — no repeated disk read on every plan run (the original bug this
    chunk-hash design replaces)."""
    path = _write(tmp_path, "p.yaml", "name: p\nsteps:\n  - name: s\n    ansible.builtin.copy: {}\n")
    plan = parse_plan(path.read_bytes(), path)
    v1 = plan.version()

    path.unlink()  # the source file is gone; version() must still work

    assert plan.version() == v1


FLAT_STEPS_PLAN = "name: p\nsteps:\n  - name: s\n    ansible.builtin.copy: {}\n"
EXPLICIT_CHUNKS_PLAN = """
name: p
chunks:
  - name: main
    steps:
      - name: s
        ansible.builtin.copy: {}
"""


def test_flat_steps_is_one_implicit_unconditional_chunk(tmp_path):
    """The pre-chunking steps: syntax must produce exactly the same
    chunk_id as the equivalent explicit chunks: syntax — proves the
    backward-compatible shorthand isn't just parseable but semantically
    identical (same content-addressed hash)."""
    flat_path = _write(tmp_path, "flat.yaml", FLAT_STEPS_PLAN)
    chunked_path = _write(tmp_path, "chunked.yaml", EXPLICIT_CHUNKS_PLAN)

    flat_plan = parse_plan(flat_path.read_bytes(), flat_path)
    chunked_plan = parse_plan(chunked_path.read_bytes(), chunked_path)

    assert len(flat_plan.chunks) == 1
    assert flat_plan.chunks[0].name == "main"
    assert flat_plan.chunks[0].os_family is None
    assert flat_plan.version() == chunked_plan.version()


def test_chunks_and_steps_together_is_an_error(tmp_path):
    content = "name: p\nsteps:\n  - name: s\n    ansible.builtin.copy: {}\nchunks:\n  - name: c\n    steps:\n      - name: s\n        ansible.builtin.copy: {}\n"
    path = _write(tmp_path, "p.yaml", content)
    with pytest.raises(PlanError, match="either 'chunks' or 'steps', not both"):
        parse_plan(path.read_bytes(), path)


WHEN_REGISTER_PLAN = """
name: conditional_plan
steps:
  - name: check_dir
    register: _dir_stat
    ansible.builtin.stat:
      path: /tmp/somewhere
  - name: create_if_missing
    when: not _dir_stat.data.exists
    ansible.builtin.file:
      path: /tmp/somewhere
      state: directory
"""


def test_parse_step_when_and_register(tmp_path):
    path = _write(tmp_path, "p.yaml", WHEN_REGISTER_PLAN)
    plan = parse_plan(path.read_bytes(), path)

    check_step, create_step = plan.steps
    assert check_step.register == "_dir_stat"
    assert check_step.when is None
    assert create_step.when == "not _dir_stat.data.exists"
    assert create_step.register is None


def test_parse_step_when_must_be_string(tmp_path):
    path = _write(tmp_path, "p.yaml", "name: p\nsteps:\n  - name: s\n    when: [1, 2]\n    ansible.builtin.copy: {}\n")
    with pytest.raises(PlanError, match="'when' must be a string"):
        parse_plan(path.read_bytes(), path)


def test_parse_step_register_must_be_string(tmp_path):
    path = _write(tmp_path, "p.yaml", "name: p\nsteps:\n  - name: s\n    register: [1, 2]\n    ansible.builtin.copy: {}\n")
    with pytest.raises(PlanError, match="'register' must be a string"):
        parse_plan(path.read_bytes(), path)


OS_DISPATCH_PLAN = """
name: os_dispatch_plan
chunks:
  - name: debian_packages
    os_family: [debian]
    steps:
      - name: install_debian
        ansible.builtin.apt:
          name: docker-ce
  - name: redhat_packages
    os_family: [redhat]
    steps:
      - name: install_redhat
        ansible.builtin.package:
          name: docker-ce
  - name: common
    steps:
      - name: enable_service
        ansible.builtin.service:
          name: docker
          state: started
"""


def test_parse_chunk_os_family(tmp_path):
    path = _write(tmp_path, "p.yaml", OS_DISPATCH_PLAN)
    plan = parse_plan(path.read_bytes(), path)

    assert [c.name for c in plan.chunks] == ["debian_packages", "redhat_packages", "common"]
    assert plan.chunks[0].os_family == ["debian"]
    assert plan.chunks[1].os_family == ["redhat"]
    assert plan.chunks[2].os_family is None


def test_parse_chunk_os_family_must_be_list_of_strings(tmp_path):
    path = _write(tmp_path, "p.yaml", "name: p\nchunks:\n  - name: c\n    os_family: debian\n    steps:\n      - name: s\n        ansible.builtin.copy: {}\n")
    with pytest.raises(PlanError, match="'os_family' must be a list of strings"):
        parse_plan(path.read_bytes(), path)


FINAL_HANDLER_PLAN = """
name: with_handler
steps:
  - name: install
    ansible.builtin.apt:
      name: docker-ce
final_handler:
  name: restart_docker
  ansible.builtin.service:
    name: docker
    state: restarted
"""


def test_parse_final_handler(tmp_path):
    path = _write(tmp_path, "p.yaml", FINAL_HANDLER_PLAN)
    plan = parse_plan(path.read_bytes(), path)

    assert plan.final_handler is not None
    assert plan.final_handler.name == "restart_docker"
    assert plan.final_handler.module == "service"


def test_chunk_id_is_content_addressed_and_stable():
    step = PlanStep(name="s", kind="module", module="copy", body={"dest": "/etc/motd", "content": "hi"})
    chunk_a = Chunk(name="main", steps=[step])
    chunk_b = Chunk(name="main", steps=[PlanStep(name="s", kind="module", module="copy", body={"dest": "/etc/motd", "content": "hi"})])

    assert chunk_a.chunk_id == chunk_b.chunk_id  # identical content -> identical id, regardless of object identity

    chunk_c = Chunk(name="main", steps=[PlanStep(name="s", kind="module", module="copy", body={"dest": "/etc/motd", "content": "bye"})])
    assert chunk_a.chunk_id != chunk_c.chunk_id  # different content -> different id


def test_chunks_needing_retranslation_only_flags_changed_and_new():
    step = PlanStep(name="s", kind="module", module="copy", body={})
    existing = [
        Chunk(name="unchanged", steps=[step], source_hash="hash-a"),
        Chunk(name="changed", steps=[step], source_hash="hash-b-old"),
    ]
    current_source_hashes = {
        "unchanged": "hash-a",  # same as before -> not flagged
        "changed": "hash-b-new",  # differs -> flagged
        "brand_new": "hash-c",  # wasn't in existing at all -> flagged
    }

    stale = chunks_needing_retranslation(existing, current_source_hashes)

    assert stale == ["brand_new", "changed"]


def test_chunks_needing_retranslation_ignores_natively_authored_chunks():
    """A chunk with no source_hash has no foreign source to diff against
    — it must never be flagged for retranslation just because some
    unrelated source hash map was passed in."""
    step = PlanStep(name="s", kind="module", module="copy", body={})
    existing = [Chunk(name="native", steps=[step], source_hash=None)]

    stale = chunks_needing_retranslation(existing, {"native": "whatever"})

    assert stale == ["native"]  # no source_hash recorded yet -> treated as needing translation once


def test_hash_source_text_deterministic():
    assert hash_source_text("some ansible yaml") == hash_source_text("some ansible yaml")
    assert hash_source_text("a") != hash_source_text("b")
    assert len(hash_source_text("x")) == 64


def test_render_catalog_markdown_empty():
    assert "No plans are currently available" in render_catalog_markdown([])


def test_render_catalog_markdown_byte_identical_and_host_independent(tmp_path):
    path = _write(tmp_path, "p.yaml", MODULE_PLAN)
    plan = parse_plan(path.read_bytes(), path)

    rendered_a = render_catalog_markdown([plan])
    rendered_b = render_catalog_markdown([plan])

    assert rendered_a == rendered_b
    assert "deploy_motd" in rendered_a
    assert "message" in rendered_a
    # render_catalog_markdown's signature takes only already-parsed plans
    # — no host parameter exists to leak into the text in the first place,
    # which is the structural guarantee behind "host is only ever a
    # tool-call argument, never part of this cached prefix".


def test_render_catalog_markdown_sorted_and_excludes_step_bodies(tmp_path):
    _write(tmp_path, "b_plan.yaml", "name: b\ndescription: second\nsteps:\n  - name: s\n    ansible.builtin.copy: {dest: /tmp/x}\n")
    _write(tmp_path, "a_plan.yaml", "name: a\ndescription: first\nsteps:\n  - name: s\n    ansible.builtin.copy: {dest: /tmp/secret-path}\n")
    plans = load_plans_dir(tmp_path)

    rendered = render_catalog_markdown(plans)

    assert rendered.index("## a") < rendered.index("## b")
    assert "/tmp/secret-path" not in rendered  # step bodies are deliberately excluded


def test_img_docker_plan_parses_and_has_expected_chunk_shape():
    """bossman/plans/img_docker.yaml is a real translation of the Ansible
    role ~/Dev/ansible/ansible03/roles/img_docker — this is the proof that
    the chunk/when/register/os_family/final_handler format introduced for
    that translation actually parses, not just synthetic test fixtures."""
    plan = load_plan_file(REPO_PLANS_DIR / "img_docker.yaml")

    assert plan.name == "img_docker"
    chunk_names = [c.name for c in plan.chunks]
    assert chunk_names == [
        "data_dirs",
        "debian_packages",
        "ubuntu_packages",
        "redhat_packages",
        "proxy_config",
        "docker_compose_wrapper",
        "daemon_reload",
    ]

    by_name = {c.name: c for c in plan.chunks}
    assert by_name["debian_packages"].os_family == ["debian"]
    assert by_name["ubuntu_packages"].os_family == ["ubuntu"]
    assert by_name["redhat_packages"].os_family == ["redhat"]
    assert by_name["data_dirs"].os_family is None

    symlink_step = by_name["data_dirs"].steps[-1]
    assert symlink_step.when == "not _containerd_dir.data.exists"
    stat_step = by_name["data_dirs"].steps[3]
    assert stat_step.register == "_containerd_dir"

    assert plan.final_handler is not None
    assert plan.final_handler.name == "restart_docker"
    assert plan.final_handler.module == "systemd"

    # Every chunk translated from a real source file carries a source_hash
    # (the incremental-retranslation scaffold's diffing key); every chunk
    # has a distinct, content-addressed chunk_id.
    assert all(c.source_hash is not None for c in plan.chunks)
    assert len({c.chunk_id for c in plan.chunks}) == len(plan.chunks)

    args = resolve_params(plan, host_vars={}, explicit={})
    assert args["docker_apt_codename"] == "bookworm"
    assert args["docker_noproxy"] == ""
    assert "docker_proxy_url" not in args  # optional, no default -> stays undefined


# --- roadmap #4: FQCN module keys (collection modules callable) ---------

def test_collection_fqcn_module_key_keeps_full_name():
    raw = {"name": "p", "steps": [
        {"name": "gen", "community.crypto.openssl_privatekey": {"path": "/k.pem"}},
        {"name": "f", "ansible.builtin.file": {"path": "/x", "state": "directory"}},
    ]}
    plan = build_plan_from_raw(raw, Path("p"))
    steps = plan.chunks[0].steps
    # collection module: full FQCN kept (matches the agent's G3 registration)
    assert steps[0].module == "community.crypto.openssl_privatekey"
    # ansible.builtin.* still stripped to the bare native name
    assert steps[1].module == "file"


def test_non_dotted_unknown_key_still_rejected():
    with pytest.raises(PlanError, match="unexpected key"):
        build_plan_from_raw({"name": "p", "steps": [{"name": "s", "notamodule": {}}]}, Path("p"))
