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


async def test_set_fact_folds_into_context():
    # set_fact is controller-side (no agent call) and its facts are visible to
    # later steps' args and when:, exactly like Ansible.
    rb = parse_document(
        "name: t\nsteps:\n"
        "  -\n    name: compute\n    module: set_fact\n    args:\n      svc: nginx\n      want: true\n"
        "  -\n    name: use\n    module: service\n    when: want\n    args:\n      name: ${svc}\n"
    )
    client = FakeClient()
    res = await run_runbook(rb, client)
    assert [c[0] for c in client.calls] == ["service"]          # set_fact made no agent call
    assert client.calls[0][1]["name"] == "nginx"                # fact used in args
    assert res.steps[0].module == "set_fact" and res.steps[0].status == "ok"


async def test_registered_result_usable_in_later_args():
    # a registered result threads into {{ }} templating, not just when:.
    rb = parse_document(
        "name: t\nsteps:\n"
        "  -\n    name: probe\n    module: command\n    register: r\n    args:\n      cmd: hostname\n"
        "  -\n    name: echo\n    module: command\n    args:\n      cmd: echo {{ r.changed }}\n"
    )
    client = FakeClient({"command": {"changed": True}})
    await run_runbook(rb, client)
    assert client.calls[1][1]["cmd"] == "echo True"


async def test_jinja_filter_in_args():
    rb = parse_document(
        "name: t\nsteps:\n  -\n    module: apt\n    args:\n      name: {{ pkg | default('curl') }}\n"
    )
    client = FakeClient()
    await run_runbook(rb, client, {})
    assert client.calls[0][1]["name"] == "curl"


async def test_notify_runs_handler_on_change():
    rb = parse_document(
        "name: t\nsteps:\n"
        "  -\n    name: drop config\n    module: template\n    notify:\n      - restart web\n    args:\n      dest: /etc/x\n"
        "handlers:\n"
        "  -\n    name: restart web\n    module: service\n    args:\n      name: nginx\n      state: restarted\n"
    )
    client = FakeClient({"template": {"changed": True}})
    res = await run_runbook(rb, client)
    # handler ran once, AFTER the task
    assert [c[0] for c in client.calls] == ["template", "service"]
    assert res.steps[-1].name == "restart web" and res.steps[-1].module == "service"


async def test_notify_skips_handler_when_unchanged():
    rb = parse_document(
        "name: t\nsteps:\n"
        "  -\n    name: drop config\n    module: template\n    notify:\n      - restart web\n    args:\n      dest: /etc/x\n"
        "handlers:\n"
        "  -\n    name: restart web\n    module: service\n    args:\n      name: nginx\n"
    )
    client = FakeClient({"template": {"changed": False}})   # no change -> handler not fired
    res = await run_runbook(rb, client)
    assert [c[0] for c in client.calls] == ["template"]
    assert not any(s.name == "restart web" for s in res.steps)


async def test_tag_selection_only_and_skip_and_always():
    rb = parse_document(
        "name: t\nsteps:\n"
        "  -\n    name: pkg\n    module: apt\n    tags:\n      - install\n    args:\n      name: nginx\n"
        "  -\n    name: cfg\n    module: template\n    tags:\n      - config\n    args:\n      dest: /etc/x\n"
        "  -\n    name: ping\n    module: ping\n    tags:\n      - always\n"
        "  -\n    name: untagged\n    module: command\n    args:\n      cmd: hi\n"
    )
    # only_tags=install -> apt + always-tagged ping; not cfg, not untagged
    c1 = FakeClient()
    await run_runbook(rb, c1, only_tags={"install"})
    assert [c[0] for c in c1.calls] == ["apt", "ping"]
    # skip_tags=config -> everything but cfg
    c2 = FakeClient()
    await run_runbook(rb, c2, skip_tags={"config"})
    assert [c[0] for c in c2.calls] == ["apt", "ping", "command"]
    # no tag filter -> all run
    c3 = FakeClient()
    await run_runbook(rb, c3)
    assert [c[0] for c in c3.calls] == ["apt", "template", "ping", "command"]


_BLOCK_RB = (
    "name: t\nsteps:\n"
    "  -\n    name: b\n"
    "    block:\n"
    "      -\n        name: risky\n        module: command\n        args:\n          cmd: x\n"
    "      -\n        name: after\n        module: ping\n"
    "    rescue:\n"
    "      -\n        name: recover\n        module: shell\n        args:\n          cmd: fix\n"
    "    always:\n"
    "      -\n        name: cleanup\n        module: file\n        args:\n          path: /tmp/x\n"
)


async def test_block_success_runs_block_and_always_not_rescue():
    rb = parse_document(_BLOCK_RB)
    client = FakeClient()   # everything ok
    res = await run_runbook(rb, client)
    assert [c[0] for c in client.calls] == ["command", "ping", "file"]   # no rescue
    assert not res.aborted


async def test_block_failure_runs_rescue_and_recovers():
    rb = parse_document(_BLOCK_RB)
    client = FakeClient({"command": {"failed": True, "error": "boom"}})   # risky fails
    res = await run_runbook(rb, client)
    # risky fails -> 'after' skipped, rescue runs, always runs; rescue recovered
    assert [c[0] for c in client.calls] == ["command", "shell", "file"]
    assert not res.aborted


async def test_block_rescue_also_fails_aborts_after_always():
    rb = parse_document(_BLOCK_RB)
    client = FakeClient({"command": {"failed": True, "error": "boom"},
                         "shell": {"failed": True, "error": "still broken"}})
    res = await run_runbook(rb, client)
    assert [c[0] for c in client.calls] == ["command", "shell", "file"]   # always still ran
    assert res.aborted


async def test_handlers_run_once_in_definition_order():
    rb = parse_document(
        "name: t\nsteps:\n"
        "  -\n    name: a\n    module: template\n    notify:\n      - h2\n      - h1\n    args:\n      dest: /a\n"
        "  -\n    name: b\n    module: template\n    notify:\n      - h1\n    args:\n      dest: /b\n"
        "handlers:\n"
        "  -\n    name: h1\n    module: command\n    args:\n      cmd: one\n"
        "  -\n    name: h2\n    module: command\n    args:\n      cmd: two\n"
    )
    client = FakeClient({"template": {"changed": True}})
    res = await run_runbook(rb, client)
    handler_cmds = [c[1]["cmd"] for c in client.calls if c[0] == "command"]
    assert handler_cmds == ["one", "two"]   # definition order, each once (not notify order)
