"""The runbook engine: when / loop / register / check_mode / vars / notify / tags / block.

Documents are built here through `parse_playbook` — the real authoring path — so these tests exercise the
same Ansible-task syntax an operator writes. (They used to be written in NestedText, which is gone.)
"""

from bossman.services.ansible_playbook import parse_playbook
from bossman.services.nt_engine import run_runbook


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


def rb(tasks_yaml: str, handlers_yaml: str = ""):
    """A runbook from Ansible task YAML. `tasks_yaml` is the task list body (already indented as list items)."""
    doc = f"name: t\ntasks:\n{tasks_yaml}"
    if handlers_yaml:
        doc += f"handlers:\n{handlers_yaml}"
    return parse_playbook(doc)


async def test_runs_steps_in_order_with_status():
    doc = rb(
        "  - name: a\n    ping:\n"
        "  - name: b\n    apt:\n      name: nginx\n"
    )
    client = FakeClient({"apt": {"changed": True, "msg": "installed"}})
    res = await run_runbook(doc, client)
    assert [c[0] for c in client.calls] == ["ping", "apt"]
    assert [s.status for s in res.steps] == ["ok", "changed"]
    assert res.ok and res.changed


async def test_check_mode_passes_dry_run():
    client = FakeClient()
    await run_runbook(rb("  - apt:\n      name: nginx\n"), client, check_mode=True)
    assert client.calls[0][1].get("dry_run") is True


async def test_variable_substitution_in_args():
    client = FakeClient()
    await run_runbook(rb("  - apt:\n      name: '{{ pkg }}'\n"), client, {"pkg": "nginx"})
    assert client.calls[0][1]["name"] == "nginx"


async def test_when_false_skips_step():
    doc = rb("  - name: gated\n    apt:\n      name: nginx\n    when: enable == true\n")
    client = FakeClient()
    res = await run_runbook(doc, client, {"enable": False})
    assert res.steps[0].status == "skipped"
    assert client.calls == []          # skipped -> no agent call


_REGISTER_RB = (
    "  - name: drop config\n    template:\n      dest: /etc/x\n    register: cfg\n"
    "  - name: reload\n    service:\n      name: nginx\n    when: cfg.changed\n"
)


async def test_register_then_when_references_it():
    client = FakeClient({"template": {"changed": True, "msg": "wrote"}})
    res = await run_runbook(rb(_REGISTER_RB), client)
    # the service reload ran because cfg.changed was true
    assert [c[0] for c in client.calls] == ["template", "service"]
    assert res.steps[1].status in ("ok", "changed")


async def test_register_false_when_skips():
    client = FakeClient({"template": {"changed": False}})   # no change -> reload skipped
    res = await run_runbook(rb(_REGISTER_RB), client)
    assert [c[0] for c in client.calls] == ["template"]
    assert res.steps[1].status == "skipped"


async def test_loop_iterates_binding_item():
    doc = rb("  - user:\n      name: '{{ item }}'\n    loop:\n      - alice\n      - bob\n")
    client = FakeClient()
    res = await run_runbook(doc, client)
    assert [c[1]["name"] for c in client.calls] == ["alice", "bob"]
    assert len([s for s in res.steps if s.module == "user"]) == 2


async def test_failure_aborts_unless_ignored():
    doc = rb(
        "  - name: boom\n    command: x\n"
        "  - name: after\n    ping:\n"
    )
    client = FakeClient({"command": {"failed": True, "error": "nope"}})
    res = await run_runbook(doc, client)
    assert res.aborted and not res.ok
    assert [c[0] for c in client.calls] == ["command"]   # 'after' never ran


async def test_ignore_errors_continues():
    doc = rb(
        "  - name: boom\n    command: x\n    ignore_errors: true\n"
        "  - name: after\n    ping:\n"
    )
    client = FakeClient({"command": {"failed": True, "error": "nope"}})
    res = await run_runbook(doc, client)
    assert not res.aborted
    assert [c[0] for c in client.calls] == ["command", "ping"]


async def test_set_fact_folds_into_context():
    # set_fact is controller-side (no agent call) and its facts are visible to
    # later steps' args and when:, exactly like Ansible.
    doc = rb(
        "  - name: compute\n    set_fact:\n      svc: nginx\n      want: true\n"
        "  - name: use\n    service:\n      name: '{{ svc }}'\n    when: want\n"
    )
    client = FakeClient()
    res = await run_runbook(doc, client)
    assert [c[0] for c in client.calls] == ["service"]          # set_fact made no agent call
    assert client.calls[0][1]["name"] == "nginx"                # fact used in args
    assert res.steps[0].module == "set_fact" and res.steps[0].status == "ok"


async def test_registered_result_usable_in_later_args():
    # a registered result threads into {{ }} templating, not just when:.
    doc = rb(
        "  - name: probe\n    command: hostname\n    register: r\n"
        "  - name: echo\n    command: echo {{ r.changed }}\n"
    )
    client = FakeClient({"command": {"changed": True}})
    await run_runbook(doc, client)
    assert client.calls[1][1]["cmd"] == "echo True"


async def test_jinja_filter_in_args():
    client = FakeClient()
    await run_runbook(rb("  - apt:\n      name: \"{{ pkg | default('curl') }}\"\n"), client, {})
    assert client.calls[0][1]["name"] == "curl"


_NOTIFY_TASKS = "  - name: drop config\n    template:\n      dest: /etc/x\n    notify:\n      - restart web\n"


async def test_notify_runs_handler_on_change():
    doc = rb(_NOTIFY_TASKS, "  - name: restart web\n    service:\n      name: nginx\n      state: restarted\n")
    client = FakeClient({"template": {"changed": True}})
    res = await run_runbook(doc, client)
    # handler ran once, AFTER the task
    assert [c[0] for c in client.calls] == ["template", "service"]
    assert res.steps[-1].name == "restart web" and res.steps[-1].module == "service"


async def test_notify_skips_handler_when_unchanged():
    doc = rb(_NOTIFY_TASKS, "  - name: restart web\n    service:\n      name: nginx\n")
    client = FakeClient({"template": {"changed": False}})   # no change -> handler not fired
    res = await run_runbook(doc, client)
    assert [c[0] for c in client.calls] == ["template"]
    assert not any(s.name == "restart web" for s in res.steps)


async def test_tag_selection_only_and_skip_and_always():
    doc = rb(
        "  - name: pkg\n    apt:\n      name: nginx\n    tags:\n      - install\n"
        "  - name: cfg\n    template:\n      dest: /etc/x\n    tags:\n      - config\n"
        "  - name: ping\n    ping:\n    tags:\n      - always\n"
        "  - name: untagged\n    command: hi\n"
    )
    # only_tags=install -> apt + always-tagged ping; not cfg, not untagged
    c1 = FakeClient()
    await run_runbook(doc, c1, only_tags={"install"})
    assert [c[0] for c in c1.calls] == ["apt", "ping"]
    # skip_tags=config -> everything but cfg
    c2 = FakeClient()
    await run_runbook(doc, c2, skip_tags={"config"})
    assert [c[0] for c in c2.calls] == ["apt", "ping", "command"]
    # no tag filter -> all run
    c3 = FakeClient()
    await run_runbook(doc, c3)
    assert [c[0] for c in c3.calls] == ["apt", "template", "ping", "command"]


_BLOCK_TASKS = (
    "  - name: b\n"
    "    block:\n"
    "      - name: risky\n        command: x\n"
    "      - name: after\n        ping:\n"
    "    rescue:\n"
    "      - name: recover\n        shell: fix\n"
    "    always:\n"
    "      - name: cleanup\n        file:\n          path: /tmp/x\n"
)


async def test_block_success_runs_block_and_always_not_rescue():
    client = FakeClient()   # everything ok
    res = await run_runbook(rb(_BLOCK_TASKS), client)
    assert [c[0] for c in client.calls] == ["command", "ping", "file"]   # no rescue
    assert not res.aborted


async def test_block_failure_runs_rescue_and_recovers():
    client = FakeClient({"command": {"failed": True, "error": "boom"}})   # risky fails
    res = await run_runbook(rb(_BLOCK_TASKS), client)
    # risky fails -> 'after' skipped, rescue runs, always runs; rescue recovered
    assert [c[0] for c in client.calls] == ["command", "shell", "file"]
    assert not res.aborted


async def test_block_rescue_also_fails_aborts_after_always():
    client = FakeClient({"command": {"failed": True, "error": "boom"},
                         "shell": {"failed": True, "error": "still broken"}})
    res = await run_runbook(rb(_BLOCK_TASKS), client)
    assert [c[0] for c in client.calls] == ["command", "shell", "file"]   # always still ran
    assert res.aborted


async def test_handlers_run_once_in_definition_order():
    doc = rb(
        "  - name: a\n    template:\n      dest: /a\n    notify:\n      - h2\n      - h1\n"
        "  - name: b\n    template:\n      dest: /b\n    notify:\n      - h1\n",
        "  - name: h1\n    command: one\n"
        "  - name: h2\n    command: two\n",
    )
    client = FakeClient({"template": {"changed": True}})
    res = await run_runbook(doc, client)
    handler_cmds = [c[1]["cmd"] for c in client.calls if c[0] == "command"]
    assert handler_cmds == ["one", "two"]   # definition order, each once (not notify order)
