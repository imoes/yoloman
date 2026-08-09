"""The doc-shaped YAML view of a stored runbook (services/nt_convert).

Authoring is Ansible task syntax (test_ansible_playbook.py); what is left here renders the **canonical
document** as YAML for inspecting what is actually stored, and reads that shape back.
"""

import yaml

from bossman.services.nt_convert import doc_to_yaml, yaml_to_doc
from bossman.services.nt_runbook import parse_data

_DOC_YAML = """\
name: web baseline
targets: group:web
steps:
  - name: install nginx
    module: apt
    args:
      name: nginx
      state: present
  - name: cache
    run: fc-cache -f
"""


def test_yaml_to_doc_is_canonical():
    doc = yaml_to_doc(_DOC_YAML)
    assert doc["kind"] == "runbook" and doc["name"] == "web baseline"
    assert doc["targets"] == "group:web"
    assert doc["steps"][0]["module"] == "apt"
    assert doc["steps"][1]["module"] == "shell" and doc["steps"][1]["args"] == {"cmd": "fc-cache -f"}


def test_doc_to_yaml_round_trips_through_the_validator():
    doc = yaml_to_doc(_DOC_YAML)
    text = doc_to_yaml(doc)
    assert parse_data(yaml.safe_load(text)).to_dict() == doc
    assert "kind:" not in text          # internal meta key not leaked into the view


def test_role_doc_to_yaml_keeps_its_role_identity():
    doc = yaml_to_doc("role: db\nsteps:\n  - module: apt\n    args:\n      name: mysql-server\n"
                      "monitoring:\n  checks:\n    - mysql\n")
    reparsed = parse_data(yaml.safe_load(doc_to_yaml(doc))).to_dict()
    assert reparsed["kind"] == "role" and reparsed["name"] == "db"
    assert reparsed["monitoring"]["checks"] == ["mysql"]
