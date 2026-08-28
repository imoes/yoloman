"""Event-handler execution: the body, the parameters, the environment.

No database and no host: the parts that decide WHAT runs and WITH WHAT are pure, and the two
module calls are checked against a fake client that records them. That is deliberate — these
properties are the contract with the operator (docs/event-handling.md) and must be verifiable
without a fleet.
"""

import pytest

from bossman.services import event_handlers as eh


class FakeHandler:
    """Stands in for the EventHandler row — the functions under test only read attributes."""

    def __init__(self, **kw):
        self.name = kw.get("name", "h")
        self.body = kw.get("body", "script")
        self.location = kw.get("location", "managed")
        self.runbook_name = kw.get("runbook_name")
        self.interpreter = kw.get("interpreter", "bash")
        self.source = kw.get("source", "#!/bin/bash\necho hi\n")
        self.local_name = kw.get("local_name")
        self.parameters = kw.get("parameters", [])
        self.timeout_s = kw.get("timeout_s", 300)
        self.enabled = kw.get("enabled", True)


class FakeAgent:
    def __init__(self, name="web07", address="web07:8051"):
        self.name = name
        self.address = address


class FakeClient:
    """Records every module call and returns a canned payload per tool."""

    def __init__(self, replies=None, env_supported=True):
        self.calls = []
        self.probe_calls = 0
        self.replies = replies or {}
        self.env_supported = env_supported

    async def call_tool(self, tool, params):
        # The env probe (see event_handlers.supports_env) is answered by echoing the marker
        # back, which is what a current agent does. `probe_calls` keeps it out of `calls`, so
        # the assertions about which modules a run touches stay readable.
        if tool == "command" and params.get("env", {}).get("BOSSMAN_ENV_PROBE"):
            self.probe_calls += 1
            if self.env_supported:
                return {"data": {"rc": 0, "stdout": params["env"]["BOSSMAN_ENV_PROBE"], "stderr": ""}}
            return {"data": {"rc": 0, "stdout": "", "stderr": ""}}  # an old agent ignores env
        self.calls.append((tool, params))
        return {"data": self.replies.get(tool, {"rc": 0, "stdout": "", "stderr": ""})}


def test_env_name_is_shell_usable():
    # A parameter named "max-age" must not become an unusable BOSSMAN_MAX-AGE.
    assert eh.env_name("max-age") == "BOSSMAN_MAX_AGE"
    assert eh.env_name(" unit ") == "BOSSMAN_UNIT"


def test_declared_parameters_always_present_with_defaults():
    """Every declared name reaches the script: an unset variable and an empty one are different
    failures for a shell script, and only one of them is what the caller meant."""
    h = FakeHandler(parameters=[{"name": "max-age", "default": "7"}, {"name": "unit"}])
    env = eh.parameter_env(h, {"unit": "nginx"})
    assert env == {"BOSSMAN_MAX_AGE": "7", "BOSSMAN_UNIT": "nginx"}


def test_undeclared_values_are_dropped():
    """The declaration is the handler's contract; smuggling extra variables past it would make
    that contract unreadable."""
    h = FakeHandler(parameters=[{"name": "unit"}])
    assert eh.parameter_env(h, {"unit": "nginx", "SMUGGLED": "x"}) == {"BOSSMAN_UNIT": "nginx"}


def test_local_handler_gets_no_parameters():
    """The user's rule, with its reason: Bossman does not know a local script's contents, so it
    cannot describe parameters — passing values it cannot describe would be guessing."""
    h = FakeHandler(location="local", local_name="cleanup.sh", parameters=[], source=None)
    assert eh.parameter_env(h, {"unit": "nginx"}) == {}
    assert eh.missing_required(h, {}) == []


def test_missing_required_is_named():
    h = FakeHandler(parameters=[{"name": "unit", "required": True}, {"name": "opt"}])
    assert eh.missing_required(h, {}) == ["unit"]
    assert eh.missing_required(h, {"unit": "nginx"}) == []


def test_required_with_a_default_is_not_missing():
    h = FakeHandler(parameters=[{"name": "unit", "required": True, "default": "nginx"}])
    assert eh.missing_required(h, {}) == []


def test_event_context_is_complete_and_stringified():
    """Absent facts arrive as the empty string: a script cannot tell an unset variable from a
    missing one, so every name is always present."""
    ctx = eh.event_context(
        agent=FakeAgent(), service_name="CPU load", state="CRIT", value=93.5,
        handler_name="restart", run_id=None,
    )
    assert ctx["BOSSMAN_EVENT_HOST"] == "web07"
    assert ctx["BOSSMAN_EVENT_SERVICE"] == "CPU load"
    assert ctx["BOSSMAN_EVENT_STATE"] == "CRIT"
    assert ctx["BOSSMAN_EVENT_VALUE"] == "93.5"
    assert ctx["BOSSMAN_EVENT_RUN_ID"] == ""
    assert all(isinstance(v, str) for v in ctx.values())


def test_script_path_cannot_escape_the_handler_directory():
    """A local handler is named by FILE NAME, not by a path: an event handler must not be a way
    to run an arbitrary file on a host."""
    h = FakeHandler(location="local", local_name="../../etc/shadow", source=None)
    assert eh.script_path(h) == f"{eh.HANDLER_DIR}/shadow"


def test_script_path_rejects_an_unusable_name():
    h = FakeHandler(location="local", local_name="../", source=None)
    with pytest.raises(eh.HandlerError):
        eh.script_path(h)


async def test_managed_script_is_deployed_before_every_run():
    """Copy THEN command, every time. Deploying once would let a host keep an older body than
    the one Bossman displays."""
    h = FakeHandler(name="clean-logs", parameters=[{"name": "days", "default": "7"}])
    client = FakeClient()
    ok, detail = await eh.run_handler(
        None, None, FakeAgent(), h, client=client, values={"days": "3"},
        service_name="Disk /", state="CRIT", value=91,
    )
    assert ok, detail
    # file (the directory) -> copy (the body) -> command (the run). The directory step is not
    # decoration: `copy` does not create parents, so without it the deploy failed on every host
    # that had never received a handler — found by running it for real, not by reading.
    assert [t for t, _ in client.calls] == ["file", "copy", "command"]
    assert client.calls[0][1] == {"path": eh.HANDLER_DIR, "state": "directory", "mode": "0700"}

    copy_params = client.calls[1][1]
    assert copy_params["dest"] == f"{eh.HANDLER_DIR}/clean-logs"
    assert copy_params["mode"] == "0700"

    cmd_params = client.calls[2][1]
    assert cmd_params["argv"] == ["bash", f"{eh.HANDLER_DIR}/clean-logs"]
    # the rule's value wins over the default, and the event context travels with it
    assert cmd_params["env"]["BOSSMAN_DAYS"] == "3"
    assert cmd_params["env"]["BOSSMAN_EVENT_SERVICE"] == "Disk /"
    assert cmd_params["env"]["BOSSMAN_EVENT_STATE"] == "CRIT"


async def test_local_script_is_not_deployed_but_still_gets_the_context():
    h = FakeHandler(location="local", local_name="cleanup.sh", source=None, interpreter=None)
    client = FakeClient()
    ok, _ = await eh.run_handler(
        None, None, FakeAgent(), h, client=client, service_name="Disk /", state="WARN",
    )
    assert ok
    assert [t for t, _ in client.calls] == ["command"], "a local body must not be overwritten"
    env = client.calls[0][1]["env"]
    assert env["BOSSMAN_EVENT_SERVICE"] == "Disk /"
    assert not [k for k in env if not k.startswith("BOSSMAN_EVENT_")], "local takes no parameters"


async def test_non_zero_exit_is_a_recorded_failure_not_a_crash():
    """A handler that exits non-zero is a result to record. The detail names the code and the
    first output line, so the audit row says WHY rather than only that it failed."""
    h = FakeHandler(name="failing")
    client = FakeClient(replies={"command": {"rc": 3, "stderr": "unit not found\nmore"}})
    ok, detail = await eh.run_handler(None, None, FakeAgent(), h, client=client)
    assert ok is False
    assert "exited 3" in detail and "unit not found" in detail


async def test_missing_required_parameter_refuses_before_touching_the_host():
    h = FakeHandler(parameters=[{"name": "unit", "required": True}])
    client = FakeClient()
    ok, detail = await eh.run_handler(None, None, FakeAgent(), h, client=client, values={})
    assert ok is False
    assert "unit" in detail
    assert client.calls == [], "nothing may be copied or run when the call is incomplete"


async def test_unreachable_host_and_disabled_handler_are_named():
    client = FakeClient()
    ok, detail = await eh.run_handler(
        None, None, FakeAgent(address=None), FakeHandler(), client=client
    )
    assert ok is False and "address" in detail

    ok, detail = await eh.run_handler(
        None, None, FakeAgent(), FakeHandler(enabled=False), client=client
    )
    assert ok is False and "disabled" in detail
    assert client.calls == []


async def test_local_availability_reads_finds_list_payload():
    """`find` returns a LIST of {path,…}; treating it as a dict (as the disk_ops helper does)
    made every local handler look missing."""
    client = FakeClient(replies={"find": [
        {"path": f"{eh.HANDLER_DIR}/cleanup.sh", "isdir": False, "size": 12},
        {"path": f"{eh.HANDLER_DIR}/other.sh", "isdir": False, "size": 3},
    ]})
    avail = await eh.local_availability(client, ["cleanup.sh", "absent.sh"])
    assert avail == {"cleanup.sh": True, "absent.sh": False}


async def test_local_availability_reports_all_missing_when_the_call_fails():
    class Boom:
        async def call_tool(self, tool, params):
            raise RuntimeError("host unreachable")

    assert await eh.local_availability(Boom(), ["cleanup.sh"]) == {"cleanup.sh": False}


async def test_an_agent_that_ignores_env_is_refused_not_run_blind():
    """The dangerous case, measured on a real host before this guard existed: an agent older than
    the `env` parameter ignores it, so the script ran with rc 0 and an EMPTY context — success
    reported for the wrong work. A refusal naming the reason is the only honest outcome.
    """
    client = FakeClient(env_supported=False)
    ok, detail = await eh.run_handler(
        None, None, FakeAgent(), FakeHandler(), client=client, service_name="Disk /",
    )
    assert ok is False
    assert "environment" in detail and "update the agent" in detail
    assert client.calls == [], "nothing may be deployed or run on such a host"
