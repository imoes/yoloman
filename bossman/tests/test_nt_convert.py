"""Block G11 — NT/YAML ↔ canonical-JSON converter (runbook persistence)."""

from bossman.services.nt_convert import doc_to_nt, nt_to_doc, yaml_to_doc
from bossman.services.nt_runbook import parse_document

_NT = """\
name: web baseline
targets: group:web
steps:
  -
    name: install nginx
    module: apt
    args:
      name: nginx
      state: present
  -
    name: cache
    run: fc-cache -f
"""


def test_nt_to_doc_is_canonical():
    doc = nt_to_doc(_NT)
    assert doc["kind"] == "runbook" and doc["name"] == "web baseline"
    assert doc["targets"] == "group:web"
    assert doc["steps"][0]["module"] == "apt"
    assert doc["steps"][1]["module"] == "shell" and doc["steps"][1]["args"] == {"cmd": "fc-cache -f"}


def test_doc_to_nt_round_trips_through_parser():
    # doc -> NT -> parse again yields the same canonical doc (run: normalized
    # to shell, which is fine).
    doc = nt_to_doc(_NT)
    nt = doc_to_nt(doc)
    assert parse_document(nt).to_dict() == doc
    assert "kind:" not in nt          # internal meta key not leaked into authoring text


def test_role_doc_to_nt():
    role_nt = "role: db\nsteps:\n  -\n    module: apt\n    args:\n      name: mysql-server\nmonitoring:\n  checks:\n    - mysql\n"
    doc = nt_to_doc(role_nt)
    nt = doc_to_nt(doc)
    reparsed = parse_document(nt).to_dict()
    assert reparsed["kind"] == "role" and reparsed["name"] == "db"
    assert reparsed["monitoring"]["checks"] == ["mysql"]


def test_yaml_import():
    y = "name: from-yaml\nsteps:\n  - name: ping\n    module: ping\n"
    doc = yaml_to_doc(y)
    assert doc["name"] == "from-yaml" and doc["steps"][0]["module"] == "ping"
