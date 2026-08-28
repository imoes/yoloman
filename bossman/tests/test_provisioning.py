"""Block G9-P3d — credential provisioning (render + run a YAML recipe, produce the check's monitoring
params). Fake agent client; no live host."""

import yaml

from bossman.services import provisioning

# YAML, and the quoting matters: `{monitor_password}` is a placeholder this code substitutes, and YAML reads a
# bare `{...}` as a flow mapping. In NestedText everything was a string and no quoting was needed — that
# convenience is exactly what the second format cost everywhere else.
_RECIPE_YAML = """\
check: mysql
title: Create a MySQL monitoring user
admin_params:
  admin_user: MySQL admin user
  admin_password: MySQL admin password
secret_params:
  - admin_password
generate:
  - monitor_password
argv:
  - mysql
  - "-u{admin_user}"
  - "-p{admin_password}"
  - -e
  - "CREATE USER 'monitor'@'localhost' IDENTIFIED BY '{monitor_password}';"
produces:
  user: monitor
  password: "{monitor_password}"
"""

_RECIPE = yaml.safe_load(_RECIPE_YAML)


class FakeClient:
    def __init__(self, rc=0, stderr=""):
        self.rc = rc
        self.stderr = stderr
        self.calls = []

    async def call_tool(self, name, body):
        self.calls.append((name, body))
        return {"changed": True, "msg": "ran", "data": {"rc": self.rc, "stdout": "", "stderr": self.stderr}}


def test_load_recipe_from_dir(tmp_path):
    # .provision.yaml — the NestedText variant is gone with the dependency.
    (tmp_path / "mysql.provision.yaml").write_text(_RECIPE_YAML, encoding="utf-8")
    r = provisioning.load_recipe(tmp_path, "mysql")
    assert r and r["check"] == "mysql"
    assert provisioning.load_recipe(tmp_path, "nope") is None


def test_admin_param_specs_marks_secret():
    specs = {s["name"]: s for s in provisioning.admin_param_specs(_RECIPE)}
    assert specs["admin_user"]["secret"] is False
    assert specs["admin_password"]["secret"] is True
    assert all(s["required"] for s in specs.values())


async def test_provision_generates_and_substitutes():
    client = FakeClient(rc=0)
    res = await provisioning.provision(client, _RECIPE, {"admin_user": "root", "admin_password": "s3cret"})
    assert res["ok"] is True
    assert res["produced_params"]["user"] == "monitor"
    pw = res["produced_params"]["password"]
    assert pw and pw != "{monitor_password}"
    _, body = client.calls[0]
    assert client.calls[0][0] == "command"
    assert "-uroot" in body["argv"] and "-ps3cret" in body["argv"]
    assert any(pw in a for a in body["argv"])          # generated pw injected into the SQL
    assert "s3cret" not in str(res["produced_params"])  # admin creds never leak


async def test_provision_missing_admin_param():
    client = FakeClient()
    res = await provisioning.provision(client, _RECIPE, {"admin_user": "root"})
    assert res["ok"] is False and "admin_password" in res["error"]
    assert client.calls == []                           # nothing was run


async def test_provision_command_failure():
    res = await provisioning.provision(FakeClient(rc=1, stderr="access denied"), _RECIPE,
                                       {"admin_user": "root", "admin_password": "x"})
    assert res["ok"] is False and "exited 1" in res["error"]
    assert res["produced_params"] == {}
