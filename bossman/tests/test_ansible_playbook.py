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


def test_block_raises():
    with pytest.raises(ap.PlaybookError):
        ap.parse_playbook("- block:\n    - ping:\n")


def test_ambiguous_two_module_keys_raises():
    with pytest.raises(ap.PlaybookError):
        ap.parse_playbook("- copy: {src: a, dest: b}\n  file: {path: c}\n")


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
