"""Ansible-task YAML ↔ canonical doc (services/ansible_playbook)."""
from __future__ import annotations

import pytest

from bossman.services import ansible_playbook as ap


def _doc(text: str) -> dict:
    return ap.parse_playbook(text).to_dict()


def test_task_list_mapping_module_as_key():
    doc = _doc(
        """
        name: web baseline
        targets: group:web-servers
        tasks:
          - name: install nginx
            ansible.builtin.apt:
              name: nginx
              state: present
          - name: reload if changed
            service:
              name: nginx
              state: reloaded
            when: dropped.changed
            register: svc
            become: true
        """
    )
    assert doc["kind"] == "runbook" and doc["name"] == "web baseline"
    assert doc["targets"] == "group:web-servers"
    s0, s1 = doc["steps"]
    assert s0["module"] == "apt" and s0["args"] == {"name": "nginx", "state": "present"}  # builtin prefix stripped
    assert s1["module"] == "service" and s1["when"] == "dropped.changed"
    assert s1["register"] == "svc" and s1["become"] is True


def test_bare_task_list():
    doc = _doc(
        """
        - copy:
            src: a
            dest: /b
        """
    )
    assert doc["name"] == "" and doc["steps"][0]["module"] == "copy"


def test_single_play_hosts_to_targets():
    doc = _doc(
        """
        - name: p
          hosts: db
          tasks:
            - ping:
        """
    )
    assert doc["targets"] == "db" and doc["steps"][0]["module"] == "ping" and doc["steps"][0]["args"] == {}


def test_free_form_shell():
    doc = _doc("- shell: echo hi\n")
    assert doc["steps"][0]["module"] == "shell" and doc["steps"][0]["args"] == {"cmd": "echo hi"}


def test_loop_and_with_items_and_tags():
    doc = _doc(
        """
        - apt:
            name: "{{ item }}"
          with_items: [nginx, curl]
          tags: [pkg, web]
        """
    )
    step = doc["steps"][0]
    assert step["loop"] == ["nginx", "curl"] and step["tags"] == ["pkg", "web"]


def test_block_rescue_always_parses_and_round_trips():
    src = (
        "- name: guarded\n"
        "  block:\n"
        "    - name: try\n      command: {cmd: /usr/bin/thing}\n"
        "  rescue:\n"
        "    - name: fix\n      shell: {cmd: cleanup}\n"
        "  always:\n"
        "    - name: note\n      command: {cmd: echo done}\n"
    )
    doc = _doc(src)
    b = doc["steps"][0]
    assert "block" in b and "module" not in b   # block identified by the block key
    assert [c["name"] for c in b["block"]] == ["try"]
    assert b["rescue"][0]["module"] == "shell" and b["always"][0]["name"] == "note"
    # doc -> YAML -> doc is stable
    assert ap.parse_playbook(ap.doc_to_playbook(doc)).to_dict() == doc


def test_handlers_section_parses_and_round_trips():
    src = (
        "name: web\ntargets: all\ntasks:\n"
        "  - name: drop config\n    template: {dest: /etc/nginx.conf}\n    notify: [reload nginx]\n"
        "handlers:\n"
        "  - name: reload nginx\n    service: {name: nginx, state: reloaded}\n"
    )
    doc = _doc(src)
    assert doc["steps"][0]["notify"] == ["reload nginx"]
    assert doc["handlers"][0]["name"] == "reload nginx" and doc["handlers"][0]["module"] == "service"
    # doc -> YAML -> doc keeps the handlers section
    assert ap.parse_playbook(ap.doc_to_playbook(doc)).to_dict() == doc


def test_ambiguous_two_module_keys_raises():
    with pytest.raises(ap.PlaybookError):
        ap.parse_playbook("- copy: {src: a, dest: b}\n  file: {path: c}\n")


def test_doc_to_playbook_handles_run_and_runbook_sugar():
    # stored (wizard-seeded) docs carry the loose NT sugar: a step with `run:` or
    # `runbook:` instead of `module:`. doc_to_playbook must not emit an empty key.
    doc = {"kind": "runbook", "name": "w", "targets": None, "steps": [
        {"name": "validate", "run": "apachectl configtest"},
        {"name": "call", "runbook": "install-base"},
    ]}
    out = ap.doc_to_playbook(doc)
    back = ap.parse_playbook(out).to_dict()
    assert back["steps"][0]["module"] == "shell" and back["steps"][0]["args"] == {"cmd": "apachectl configtest"}
    assert "''" not in out and ": {}" not in out.replace("import_tasks", "")  # no empty module key


def test_round_trip_doc_yaml_doc():
    src = (
        "name: rt\ntargets: all\ntasks:\n"
        "  - name: t1\n    apt: {name: nginx, state: present}\n    when: x.changed\n    become: true\n"
        "  - name: t2\n    service: {name: nginx, state: started}\n    notify: [restart web]\n"
    )
    doc1 = _doc(src)
    yaml_out = ap.doc_to_playbook(doc1)
    doc2 = _doc(yaml_out)
    assert doc1 == doc2   # parse → serialize → parse is stable
