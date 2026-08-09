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


def test_failure_semantics_survive_the_whole_chain():
    """failed_when / changed_when / ignore_errors decide what counts as failure and as a change, so they
    must reach the runner. They were recognised as task keywords (not mistaken for the module) but dropped
    from the document — a silent semantic change: the run behaved differently than the playbook stated."""
    from bossman.services.ansible_playbook import doc_to_playbook, parse_playbook

    text = """
- name: risky
  command:
    cmd: /bin/false
  failed_when: rc != 0
  changed_when: rc == 0
  ignore_errors: true
- name: grouped
  block:
    - name: inner
      command:
        cmd: /bin/false
      failed_when: rc != 0
  rescue:
    - name: recover
      ping: {}
"""
    doc = parse_playbook(text).to_dict()
    first, group = doc["steps"][0], doc["steps"][1]
    assert first["failed_when"] == "rc != 0"
    assert first["changed_when"] == "rc == 0"
    assert first["ignore_errors"] is True
    # and inside a group, where a rescue actually needs it
    assert group["block"][0]["failed_when"] == "rc != 0"
    assert [c["name"] for c in group["rescue"]] == ["recover"]

    # round-trip: writing the doc back out must not lose them either
    again = parse_playbook(doc_to_playbook(doc)).to_dict()
    assert again["steps"][0]["failed_when"] == "rc != 0"
    assert again["steps"][1]["block"][0]["failed_when"] == "rc != 0"


def test_key_value_free_form_is_accepted_for_any_module():
    """`apt: update_cache=yes cache_valid_time=86400` — Ansible's untyped k=v task form. Every module
    accepts it and real roles use it constantly (geerlingguy.nginx does), so refusing it meant refusing most
    upstream Ansible. The narrow coercion is the point: Ansible's own boolean literals and plain integers
    become typed values (a module argspec would reject the string "yes" for a bool), everything else stays a
    string so quoted values survive intact."""
    from bossman.services.ansible_playbook import parse_playbook

    rb = parse_playbook('- name: Update apt cache.\n  apt: update_cache=yes cache_valid_time=86400\n')
    assert rb.steps[0].args == {"update_cache": True, "cache_valid_time": 86400}

    rb = parse_playbook('- name: restart\n  service: name="my svc" state=restarted enabled=no\n')
    assert rb.steps[0].args == {"name": "my svc", "state": "restarted", "enabled": False}


def test_documented_bare_scalar_shorthands_expand():
    """`include_vars: x.yml` means `file: x.yml` — documented, single-meaning shorthand, so it can be
    expanded. Anything else would land in Ansible's `_raw_params`, which only the module itself can decode."""
    from bossman.services.ansible_playbook import parse_playbook

    rb = parse_playbook('- name: vars\n  include_vars: "{{ ansible_facts.os_family }}.yml"\n')
    assert rb.steps[0].args["file"] == "{{ ansible_facts.os_family }}.yml"


def test_undocumented_bare_scalar_is_refused_with_a_reason():
    """The one case we must NOT guess: a bare value for a module whose free-form meaning we don't know.
    Guessing would silently run a different task than the author wrote, so it fails loudly instead."""
    import pytest

    from bossman.services.ansible_playbook import PlaybookError, parse_playbook

    with pytest.raises(PlaybookError) as exc:
        parse_playbook("- name: nope\n  some_module: just-a-value\n")
    assert "_raw_params" in str(exc.value)


def test_a_role_survives_the_text_round_trip():
    """A role rendered back to YAML must keep its `role:` key and its monitoring/notification sections.

    The text view is editable: if a role rendered as `{name, tasks}`, saving what was shown would turn it
    into a runbook and silently drop its checks and routes. That identity loss existed in the parse
    direction too (parse_data only recognised the authoring key `role:`, not the stored `kind: role`), so
    both directions are pinned here.
    """
    from bossman.services.ansible_playbook import doc_to_playbook, parse_playbook
    from bossman.services.nt_runbook import Role, parse_data

    src = ("role: db\ndescription: A database host.\nparameters:\n  port: 3306\n"
           "tasks:\n  - name: install\n    apt:\n      name: mysql-server\n"
           "monitoring:\n  checks:\n    - mysql\n    - disk\n"
           "notifications:\n  routes:\n    - dba-oncall\n")
    doc = parse_playbook(src).to_dict()

    again = parse_playbook(doc_to_playbook(doc))
    assert isinstance(again, Role)
    assert again.to_dict() == doc                      # text round-trip is lossless

    # and the stored canonical doc re-validates as a role, not a runbook
    assert parse_data(doc).kind == "role"
