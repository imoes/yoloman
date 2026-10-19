"""Fast contract tests for the role/feature deployment core.

The database-backed lifecycle is covered by the orchestration/compiler suites;
these tests pin the deterministic identities and OS applicability rules used by
preview, target synchronization and drift detection.
"""

import uuid

import pytest
from fastapi import HTTPException

from bossman.api.role_deployments import _validate_parameters
from bossman.db.models import Agent, OrchestrationPlanVersion
from bossman.services import role_deployment
from bossman.services.role_catalog import (
    _generic_catalog_doc,
    _parameter_parts,
    _template_snapshot,
    artifact_name,
)
from bossman.services.nt_runbook import Runbook, Step, parse_data


def test_target_hash_is_order_independent_and_membership_sensitive():
    one, two, three = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    assert role_deployment.target_hash([one, two]) == role_deployment.target_hash([two, one])
    assert role_deployment.target_hash([one, two]) != role_deployment.target_hash([one, two, three])


def test_desired_hash_is_stable_for_parameter_key_order_and_versioned():
    plan_id = uuid.uuid4()
    first = role_deployment.desired_hash(plan_id, 2, {"port": 443, "tls": True})
    reordered = role_deployment.desired_hash(plan_id, 2, {"tls": True, "port": 443})
    upgraded = role_deployment.desired_hash(plan_id, 3, {"port": 443, "tls": True})
    assert first == reordered
    assert first != upgraded


def test_preview_hash_locks_version_parameters_membership_and_pilot():
    host = uuid.uuid4()
    plan = uuid.uuid4()
    base = role_deployment.deployment_preview_hash(
        [host], [{"plan_id": str(plan), "version": 1, "parameters": {"port": 80}}], False,
    )
    assert base != role_deployment.deployment_preview_hash(
        [host], [{"plan_id": str(plan), "version": 2, "parameters": {"port": 80}}], False,
    )
    assert base != role_deployment.deployment_preview_hash(
        [host], [{"plan_id": str(plan), "version": 1, "parameters": {"port": 443}}], False,
    )
    assert base != role_deployment.deployment_preview_hash(
        [host], [{"plan_id": str(plan), "version": 1, "parameters": {"port": 80}}], True,
    )


def test_catalog_artifact_names_do_not_collide_with_authored_roles():
    assert artifact_name("nginx") == "catalog__nginx"


def test_parameter_schema_and_defaults_are_separated():
    schema, defaults = _parameter_parts({
        "port": {"type": "int", "default": 80, "required": True},
        "hostname": {"type": "string", "required": True},
        "legacy": "kept",
    })
    assert schema == {
        "port": {"type": "int", "default": 80, "required": True},
        "hostname": {"type": "string", "required": True},
    }
    assert defaults == {"port": 80, "legacy": "kept"}


def test_generic_catalog_artifact_supports_linux_and_windows_installers():
    doc = _generic_catalog_doc("dns", {"label": "DNS Server"})
    assert [step.get("module", "run") for step in doc["steps"]] == ["package", "run", "windows_feature", "service"]
    assert doc["steps"][2]["args"]["name"] == "{{ _features }}"
    assert len(parse_data(doc).steps) == 4


def test_family_init_runs_after_install_and_only_when_named(monkeypatch):
    """EL's postgresql postinst does not run initdb (Debian's does): the catalog's `families.redhat.init` must
    reach the runbook as `_init`, right after the install step, and an empty one must skip the step."""
    doc = _generic_catalog_doc("postgresql", {"label": "PostgreSQL"})
    init = doc["steps"][1]
    assert init["run"] == "{{ _init }}" and "_init" in init["when"]
    monkeypatch.setattr(role_deployment, "_catalog", lambda _settings: {"postgresql": {"families": {
        "redhat": {"packages": ["postgresql-server"], "service": "postgresql",
                   "init": "test -f /var/lib/pgsql/data/PG_VERSION || postgresql-setup --initdb"},
        "debian": {"packages": ["postgresql"], "service": "postgresql"}}}})
    version = OrchestrationPlanVersion(requirements={"catalog_name": "postgresql"})
    rh, _ = role_deployment.catalog_runtime(object(), Agent(name="h", token="t", facts={"os_family": "redhat"}), version)
    deb, _ = role_deployment.catalog_runtime(object(), Agent(name="h", token="t", facts={"os_family": "debian"}), version)
    assert rh["_init"].endswith("postgresql-setup --initdb")
    assert deb["_init"] == ""


def test_template_snapshot_reuses_preloaded_catalog(monkeypatch):
    monkeypatch.setattr(
        "bossman.services.role_catalog.load_template_bodies",
        lambda _settings: pytest.fail("template catalog was read again"),
    )
    steps = [{"module": "config_template", "args": {"template": "nginx"}}]
    assert _template_snapshot(object(), steps, available={"nginx": "body"}) == {"nginx": "body"}


def test_catalog_runtime_marks_missing_catalog_entry_not_applicable(monkeypatch):
    monkeypatch.setattr(role_deployment, "_catalog", lambda _settings: {})
    agent = Agent(name="host", token="token", facts={"os_family": "debian"})
    version = OrchestrationPlanVersion(requirements={"catalog_name": "gone"})
    runtime, reason = role_deployment.catalog_runtime(object(), agent, version)
    assert runtime == {}
    assert reason == "catalog item 'gone' no longer exists"


def test_authored_role_without_catalog_requirement_applies_everywhere():
    agent = Agent(name="host", token="token", facts={})
    version = OrchestrationPlanVersion(requirements={"source": "runbook-role"})
    assert role_deployment.catalog_runtime(object(), agent, version) == ({}, None)


def test_deployment_parameter_validation_blocks_hidden_runtime_overrides():
    version = OrchestrationPlanVersion(
        parameter_schema={"port": {"type": "number", "required": True},
                          "_packages": {"type": "list", "hidden": True}},
        default_parameters={},
    )
    _validate_parameters(version, {"port": 443})
    with pytest.raises(HTTPException, match="cannot be overridden"):
        _validate_parameters(version, {"port": 443, "_packages": ["unexpected"]})
    with pytest.raises(HTTPException, match="must be number"):
        _validate_parameters(version, {"port": "443"})


def test_detection_checks_service_end_state_instead_of_perpetual_restart():
    source = Runbook(name="web", steps=[
        Step(name="restart", module="service", args={"name": "nginx", "state": "restarted", "enabled": True}),
    ])
    detected = role_deployment._detection_doc(source)
    assert detected.steps[0].args["state"] == "started"
    assert source.steps[0].args["state"] == "restarted"


def test_detection_ignores_commands_so_a_validated_role_can_be_compliant():
    """The install runbook validates its config (`nginx -t`) before restarting. In check mode the agent predicts a
    command as changed, so detection reported drift right after every successful apply — measured in the package
    e2e: nginx stayed noncompliant with no reason given."""
    source = Runbook(name="r", steps=[
        Step(name="render", module="config_template", args={"template": "nginx", "dest": "/etc/nginx/nginx.conf"}),
        Step(name="validate", module="command", args={"cmd": "nginx -t"}),
        Step(name="restart", module="service", args={"name": "nginx", "state": "restarted"}),
    ])
    detected = role_deployment._detection_doc(source)
    assert [s.name for s in detected.steps] == ["render", "restart"]
    assert [s.name for s in source.steps] == ["render", "validate", "restart"]


def test_generated_install_runbooks_use_the_engines_placeholder_syntax():
    """`${_packages}` was NestedText's syntax; since its removal nothing resolves it, and every schema-generated and
    generic catalog role ran `apt-get install -y ${_packages}` (54 of the first 60 roles in the package e2e)."""
    import json as _json

    from bossman.services.role_catalog import _generic_catalog_doc
    from bossman.services.wizard_seed import _build_doc

    entry = {"label": "X", "validate_cmd": "x -t", "families": {"debian": {"packages": ["x"]}}}
    params = {"port": {"type": "number", "default": 1}, "_packages": {"type": "list", "hidden": True}}
    for doc in (_build_doc("x", entry, params, "x"), _generic_catalog_doc("x", entry)):
        text = _json.dumps(doc)
        assert "${" not in text, text
        assert "{{ _packages }}" in text


def test_preview_names_hosts_that_are_applicable_only_by_borrowed_package_names():
    """earlyoom has only a Debian branch: on AlmaLinux it is 'applicable' by installing the Debian name, which
    may not exist there (it is EPEL-only). The preview says so per host instead of a bare "1/1 applicable"."""
    version = OrchestrationPlanVersion(requirements={
        "catalog_name": "earlyoom",
        "catalog_families": {"debian": {"packages": ["earlyoom"], "service": "earlyoom"}},
    })
    alma = Agent(name="rh", facts={"os": {"id": "almalinux", "id_like": "rhel centos fedora"}})
    deb = Agent(name="deb", facts={"os": {"id": "debian"}})
    _runtime, reason = role_deployment.catalog_runtime(None, alma, version)
    assert reason is None                                     # still installable — counted as applicable
    note = role_deployment.catalog_family_note(None, alma, version)
    assert note and "No redhat entry" in note and "earlyoom" in note
    assert role_deployment.catalog_family_note(None, deb, version) is None


def test_a_closed_write_gate_is_blocked_not_an_error():
    """Measured on e2e-deb-ro: the agent's 403 arrives as a failed step, so the target read "error"."""
    msg = '192.168.49.2:30813: tool \'package\' returned 403: {"error":"tool \\"package\\" is disabled (write=false)"}'
    assert role_deployment.is_write_gate_refusal(msg)
    assert role_deployment.is_write_gate_refusal("agent is read-only")
    assert not role_deployment.is_write_gate_refusal("E: Unable to locate package earlyoom")


def test_unit_reason_picks_the_daemons_line_not_systemds(monkeypatch):
    """A failed or not-running service names the daemon's own reason, not systemd's boilerplate (Bossman-path e2e:
    "service not running: rsync.service" while the journal named the missing file)."""
    import asyncio
    from bossman.services.nt_engine import StepResult

    journal = ("Starting openvpn-server@server.service - OpenVPN service for server...\n"
               "Options error: In [CMD-LINE]:1: Error opening configuration file: server.conf\n"
               "Use --help for more information.\n"
               "openvpn-server@server.service: Main process exited, code=exited, status=1/FAILURE\n"
               "openvpn-server@server.service: Failed with result 'exit-code'.\n"
               "Failed to start openvpn-server@server.service - OpenVPN service for server.\n")
    calls = []

    class Client:
        async def call_tool(self, name, body):
            calls.append(body["cmd"])
            return {"data": {"stdout": journal}}

    step = StepResult(name="Enable and restart OpenVPN", module="service", status="failed",
                      error="systemd: restarting openvpn-server@server.service: systemctl restart …: exit status 1")
    msg = asyncio.run(role_deployment._with_unit_reasons(Client(), step.error, [step]))
    assert "journal: openvpn-server@server.service: Options error" in msg and "server.conf" in msg
    assert "openvpn-server@server.service" in calls[0]

    class Down:
        async def call_tool(self, name, body):
            raise RuntimeError("host unreachable")

    assert asyncio.run(role_deployment._with_unit_reasons(Down(), "x", [step])) == "x"


def test_a_host_without_facts_is_not_guessed_debian(monkeypatch):
    """A freshly enrolled AlmaLinux host has no facts for a few seconds; it used to count as Debian and got
    chrony.service (Debian's unit) instead of chronyd. Unknown is a named, retried state."""
    monkeypatch.setattr(role_deployment, "_catalog", lambda _settings: {"chrony": {"families": {
        "debian": {"packages": ["chrony"], "service": "chrony"},
        "redhat": {"packages": ["chrony"], "service": "chronyd"}}}})
    version = OrchestrationPlanVersion(requirements={"catalog_name": "chrony"})
    runtime, reason = role_deployment.catalog_runtime(object(), Agent(name="h", token="t", facts={}), version)
    assert runtime == {} and "not reported its OS family" in reason
    rh, _ = role_deployment.catalog_runtime(object(), Agent(name="h", token="t", facts={"os_family": "redhat"}), version)
    assert rh["_service"] == "chronyd"


def test_boot_enablement_follows_the_catalog(monkeypatch):
    """dnscache's SysV script has no runlevels: `systemctl enable` fails although the daemon runs. The catalog says
    `enable: false`; the role's service step takes `enabled` from `_enable`."""
    from bossman.services.wizard_seed import _bind_family_runtime
    monkeypatch.setattr(role_deployment, "_catalog", lambda _settings: {"dnscache": {"families": {
        "debian": {"packages": ["dnscache"], "service": "dnscache.service", "enable": False}}}})
    version = OrchestrationPlanVersion(requirements={"catalog_name": "dnscache"})
    rt, _ = role_deployment.catalog_runtime(object(), Agent(name="h", token="t", facts={"os_family": "debian"}), version)
    assert rt["_enable"] is False
    step = _bind_family_runtime({"module": "service", "args": {"name": "x", "state": "restarted", "enabled": True}})
    assert step["args"]["enabled"] == "{{ _enable }}"
    doc = _generic_catalog_doc("dnscache", {"label": "dnscache"})
    assert doc["steps"][-1]["args"]["enabled"] == "{{ _enable }}"
