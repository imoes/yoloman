"""Role -> OrchestrationPlan create-payload.

The role is written in the authoring format — Ansible task syntax under a `role:` key, with the two sections
a role owns (`monitoring.checks`, `notifications.routes`).
"""

from bossman.services.ansible_playbook import parse_playbook
from bossman.services.nt_compile import role_to_plan_input

_ROLE = """\
role: mysql_server
description: A MySQL database server.
parameters:
  mysql_port: 3306
tasks:
  - name: install
    apt:
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


def test_role_to_plan_input_shape():
    role = parse_playbook(_ROLE)
    pi = role_to_plan_input(role)
    assert pi["name"] == "mysql_server"
    assert pi["display_name"] == "Mysql Server"
    assert pi["plan_type"] == "role"
    v = pi["version"]
    assert v["default_parameters"] == {"mysql_port": 3306}
    assert v["generated_monitoring"]["checks"] == ["mysql", "disk"]
    assert v["generated_notifications"]["routes"] == ["dba-oncall"]
    assert v["steps"][0]["module"] == "apt"
    assert v["steps"][0]["args"] == {"name": "mysql-server", "state": "present"}
