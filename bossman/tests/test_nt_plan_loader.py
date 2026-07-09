"""NestedText plan front-end (Block NT). A NestedText playbook must parse to
the same Plan/Chunk/PlanStep structures as the YAML loader, with the schema's
boolean fields coerced from NestedText's all-strings representation.
"""

from pathlib import Path

import nestedtext
import pytest
import yaml

from bossman.services.nt_plan_loader import parse_plan_nt
from bossman.services.plan_loader import PlanError, build_plan_from_raw

# A NestedText playbook exercising the full surface: params (with a boolean
# `required`), multiple chunks (one OS-gated), a module step with `when` +
# `register`, a pipeline step, and a final handler. Note: no quoting on
# `mode: 0755`, and the multiline `content` uses NestedText's `>` blocks.
SAMPLE_NT = """\
name: nt_demo
description:
    > Install and start a service, NestedText-authored.
params:
    service_name:
        type: string
        required: true
    enable_it:
        type: string
        required: false
        default: yes
chunks:
    -
        name: files
        steps:
            -
                name: make_dir
                file:
                    path: /etc/demo
                    state: directory
                    mode: 0755
            -
                name: check_conf
                register: _conf
                stat:
                    path: /etc/demo/demo.conf
            -
                name: write_conf
                when: not _conf.data.exists
                copy:
                    dest: /etc/demo/demo.conf
                    content:
                        > key = value
                        > other = 1
    -
        name: debian_only
        os_family:
            - debian
        steps:
            -
                name: reload_units
                pipeline:
                    -
                        - systemctl
                        - daemon-reload
final_handler:
    name: restart_demo
    systemd:
        name: demo
        state: restarted
"""


def test_parse_nt_plan_structure():
    plan = parse_plan_nt(SAMPLE_NT, Path("nt_demo.nt"))

    assert plan.name == "nt_demo"
    assert "NestedText-authored" in plan.description

    # params: boolean `required` coerced from the NestedText string.
    assert plan.params["service_name"].required is True
    assert plan.params["enable_it"].required is False
    assert plan.params["enable_it"].default == "yes"  # a non-schema scalar stays a string

    assert [c.name for c in plan.chunks] == ["files", "debian_only"]
    assert plan.chunks[1].os_family == ["debian"]

    files = plan.chunks[0]
    assert [s.name for s in files.steps] == ["make_dir", "check_conf", "write_conf"]

    make_dir = files.steps[0]
    assert make_dir.kind == "module"
    assert make_dir.module == "file"
    # mode needs no quoting in NestedText and arrives as the string "0755".
    assert make_dir.body["mode"] == "0755"

    check_conf = files.steps[1]
    assert check_conf.register == "_conf"
    assert check_conf.module == "stat"

    write_conf = files.steps[2]
    assert write_conf.when == "not _conf.data.exists"
    assert write_conf.body["content"] == "key = value\nother = 1"

    # pipeline step
    reload_step = plan.chunks[1].steps[0]
    assert reload_step.kind == "pipeline"
    assert reload_step.pipeline == [["systemctl", "daemon-reload"]]

    # final handler
    assert plan.final_handler is not None
    assert plan.final_handler.name == "restart_demo"
    assert plan.final_handler.module == "systemd"


def test_nt_rejects_non_mapping():
    # top="dict" makes NestedText itself reject a top-level list; we surface
    # it as a clean PlanError rather than letting the raw error escape.
    with pytest.raises(PlanError, match="invalid NestedText"):
        parse_plan_nt("- just\n- a\n- list\n", Path("bad.nt"))


def test_nt_reports_invalid_syntax():
    # A line that is neither a valid key-value nor a list item at this indent.
    with pytest.raises(PlanError, match="invalid NestedText"):
        parse_plan_nt("name: ok\n  : dangling multiline key with no parent\n", Path("bad.nt"))


def test_yaml_and_nt_are_structurally_equivalent():
    """A YAML plan converted deterministically to NestedText parses to a Plan
    with the same chunk/step names and kinds — proving NestedText is a true
    alternate front-end. (chunk_id/version differ only because NestedText
    scalars are strings, e.g. `update_cache: true` → \"true\", which is the
    intended semantic — module-side coercion handles it.)"""
    yaml_plan = build_plan_from_raw(yaml.safe_load(Path("plans/img_docker.yaml").read_bytes()), Path("img_docker.yaml"))
    nt_text = nestedtext.dumps(yaml.safe_load(Path("plans/img_docker.yaml").read_bytes()))
    nt_plan = parse_plan_nt(nt_text, Path("img_docker.nt"))

    assert nt_plan.name == yaml_plan.name
    assert [c.name for c in nt_plan.chunks] == [c.name for c in yaml_plan.chunks]
    for nc, yc in zip(nt_plan.chunks, yaml_plan.chunks):
        assert [s.name for s in nc.steps] == [s.name for s in yc.steps]
        assert [s.kind for s in nc.steps] == [s.kind for s in yc.steps]
        assert nc.os_family == yc.os_family
    assert (nt_plan.final_handler is None) == (yaml_plan.final_handler is None)
