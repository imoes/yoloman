"""Block G11 step 4 — the NT run engine (when/loop/register/check_mode/vars)."""

from bossman.services.nt_engine import run_runbook
from bossman.services.nt_runbook import parse_document


class FakeClient:
    """Records call_tool(module, body); returns responses from a per-module
    map (callable or dict), default {changed: False}."""

    def __init__(self, responses=None):
        self.responses = responses or {}
        self.calls = []

    async def call_tool(self, module, body):
        self.calls.append((module, body))
        r = self.responses.get(module)
        if callable(r):
            return r(body)
        return r if r is not None else {"changed": False, "msg": "ok"}


async def test_runs_steps_in_order_with_status():
    rb = parse_document(
        "name: t\nsteps:\n"
        "  -\n    name: a\n    module: ping\n"
        "  -\n    name: b\n    module: apt\n    args:\n      name: nginx\n"
    )
    client = FakeClient({"apt": {"changed": True, "msg": "installed"}})
    res = await run_runbook(rb, client)
    assert [c[0] for c in client.calls] == ["ping", "apt"]
    assert [s.status for s in res.steps] == ["ok", "changed"]
    assert res.ok and res.changed


async def test_check_mode_passes_dry_run():
    rb = parse_document("name: t\nsteps:\n  -\n    module: apt\n    args:\n      name: nginx\n")
    client = FakeClient()
    await run_runbook(rb, client, check_mode=True)
    assert client.calls[0][1].get("dry_run") is True


async def test_variable_substitution_in_args():
    rb = parse_document("name: t\nsteps:\n  -\n    module: apt\n    args:\n      name: ${pkg}\n")
    client = FakeClient()
    await run_runbook(rb, client, {"pkg": "nginx"})
    assert client.calls[0][1]["name"] == "nginx"


async def test_when_false_skips_step():
    rb = parse_document(
        "name: t\nsteps:\n  -\n    name: gated\n    module: apt\n    when: enable == true\n    args:\n      name: nginx\n"
    )
    client = FakeClient()
    res = await run_runbook(rb, client, {"enable": False})
    assert res.steps[0].status == "skipped"
    assert client.calls == []          # skipped -> no agent call


async def test_register_then_when_references_it():
    rb = parse_document(
        "name: t\nsteps:\n"
        "  -\n    name: drop config\n    module: template\n    register: cfg\n    args:\n      dest: /etc/x\n"
        "  -\n    name: reload\n    module: service\n    when: cfg.changed\n    args:\n      name: nginx\n"
    )
    client = FakeClient({"template": {"changed": True, "msg": "wrote"}})
    res = await run_runbook(rb, client)
    # the service reload ran because cfg.changed was true
    assert [c[0] for c in client.calls] == ["template", "service"]
    assert res.steps[1].status in ("ok", "changed")


async def test_register_false_when_skips():
    rb = parse_document(
        "name: t\nsteps:\n"
        "  -\n    name: drop config\n    module: template\n    register: cfg\n    args:\n      dest: /etc/x\n"
        "  -\n    name: reload\n    module: service\n    when: cfg.changed\n    args:\n      name: nginx\n"
    )
    client = FakeClient({"template": {"changed": False}})   # no change -> reload skipped
    res = await run_runbook(rb, client)
    assert [c[0] for c in client.calls] == ["template"]
    assert res.steps[1].status == "skipped"


async def test_loop_iterates_binding_item():
    rb = parse_document(
        "name: t\nsteps:\n  -\n    module: user\n    loop:\n      - alice\n      - bob\n    args:\n      name: ${item}\n"
    )
    client = FakeClient()
    res = await run_runbook(rb, client)
    assert [c[1]["name"] for c in client.calls] == ["alice", "bob"]
    assert len([s for s in res.steps if s.module == "user"]) == 2


async def test_failure_aborts_unless_ignored():
    rb = parse_document(
        "name: t\nsteps:\n"
        "  -\n    name: boom\n    module: command\n    args:\n      cmd: x\n"
        "  -\n    name: after\n    module: ping\n"
    )
    client = FakeClient({"command": {"failed": True, "error": "nope"}})
    res = await run_runbook(rb, client)
    assert res.aborted and not res.ok
    assert [c[0] for c in client.calls] == ["command"]   # 'after' never ran


async def test_ignore_errors_continues():
    rb = parse_document(
        "name: t\nsteps:\n"
        "  -\n    name: boom\n    module: command\n    ignore_errors: true\n    args:\n      cmd: x\n"
        "  -\n    name: after\n    module: ping\n"
    )
    client = FakeClient({"command": {"failed": True, "error": "nope"}})
    res = await run_runbook(rb, client)
    assert not res.aborted
    assert [c[0] for c in client.calls] == ["command", "ping"]
