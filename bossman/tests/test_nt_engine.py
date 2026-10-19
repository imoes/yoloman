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


class _StateClient(FakeClient):
    async def state_apply(self, body, check_mode):
        self.calls.append(("state_apply", body))
        return {"changes": [{"action": "update"}]}


async def test_config_template_prefers_the_hosts_family_template_for_that_file():
    """A role names ONE template — the Debian one. Measured in the package e2e: on a RedHat host the wizard
    would have written Debian's nginx.conf (user www-data, sites-enabled). The family's own template for the
    destination file wins; without one the named template is used as before."""
    doc = rb("  - config_template:\n      template: nginx\n      dest: /etc/nginx/nginx.conf\n")
    templates = {"nginx": "user www-data;\n", "@redhat:/etc/nginx/nginx.conf": "user nginx;\n"}
    rh, deb = _StateClient(), _StateClient()
    await run_runbook(doc, rh, {"_family": "redhat"}, templates=templates)
    await run_runbook(doc, deb, {"_family": "debian"}, templates=templates)
    assert rh.calls[0][1]["resources"][0]["template"] == "user nginx;\n"
    assert deb.calls[0][1]["resources"][0]["template"] == "user www-data;\n"


def test_a_family_template_carries_its_own_defaults():
    """The role's form names the Debian template's fields; the RedHat template's `user` stayed unset and nginx got
    `user ;`. The family entry now sets every field to its own shipped default unless the form supplies it."""
    from bossman.api.config_templates import with_own_defaults

    body = with_own_defaults("user {{ user }};\nworkers {{ w }};\n",
                             {"user": {"type": "string", "default": "nginx"}, "w": {"type": "number", "default": 4},
                              "bad-name": {"default": "x"}, "unset": {"default": None}})
    assert "{%- set user = user | default(\"nginx\", true) -%}" in body
    assert "{%- set w = w | default(4, true) -%}" in body
    assert "bad-name" not in body and "unset" not in body
    import jinja2
    assert jinja2.Template(body).render() == "user nginx;\nworkers 4;"
    assert jinja2.Template(body).render(user="www-data") == "user www-data;\nworkers 4;"


async def test_on_a_family_template_the_role_defaults_yield_to_the_family_defaults():
    """The role's defaults are the Debian template's values; on AlmaLinux php-fpm got `user = www-data`. A value
    still equal to the role default is dropped for a family template (its own default applies); a value the
    operator changed is kept; the named (Debian) template still receives everything."""
    doc = rb("  - config_template:\n      template: php-fpm\n      dest: /etc/php-fpm.d/www.conf\n")
    templates = {"php-fpm": "user = {{ user }}\n",
                 "@redhat:/etc/php-fpm.d/www.conf": "user = {{ user }}\npm = {{ pm }}\n"}
    role_defaults = {"user": "www-data", "pm": "dynamic"}
    rh = _StateClient()
    await run_runbook(doc, rh, {"_family": "redhat", "user": "www-data", "pm": "static",
                                "_role_defaults": role_defaults}, templates=templates)
    values = rh.calls[0][1]["resources"][0]["values"]
    assert "user" not in values and values["pm"] == "static" and "_role_defaults" not in values
    deb = _StateClient()
    await run_runbook(doc, deb, {"_family": "debian", "user": "www-data", "_role_defaults": role_defaults},
                      templates=templates)
    assert deb.calls[0][1]["resources"][0]["values"]["user"] == "www-data"


async def test_a_set_value_the_family_file_has_no_setting_for_is_refused():
    """squid on EL ships 3 directives where Debian documents 207: a value the operator set for a Debian-only field
    would vanish on the EL host. Refused with the field named; nothing is written."""
    doc = rb("  - config_template:\n      template: squid\n      dest: /etc/squid/squid.conf\n")
    templates = {"squid": "http_port {{ http_port }}\ncache_mem {{ cache_mem }}\n",
                 "@redhat:/etc/squid/squid.conf": "http_port {{ http_port }}\n"}
    role_defaults = {"http_port": "3128", "cache_mem": "256 MB"}
    rh = _StateClient()
    res = await run_runbook(doc, rh, {"_family": "redhat", "http_port": "3128", "cache_mem": "1 GB",
                                      "_role_defaults": role_defaults}, templates=templates)
    assert not rh.calls
    assert "no setting for cache_mem" in res.steps[0].error
    ok = _StateClient()   # only fields the EL file has: rendered
    await run_runbook(doc, ok, {"_family": "redhat", "http_port": "3129", "cache_mem": "256 MB",
                                "_role_defaults": role_defaults}, templates=templates)
    assert ok.calls[0][1]["resources"][0]["values"]["http_port"] == "3129"


async def test_a_value_for_another_familys_field_is_refused_on_this_host():
    """The role's form is the union of its families' templates; `_family_only` names the fields only some files
    have. A value the operator set for an EL-only field would be written nowhere on a Debian host — refused, naming
    the field and where it applies. Left at its default it is no choice and passes; on EL it renders."""
    doc = rb("  - config_template:\n      template: squid\n      dest: /etc/squid/squid.conf\n")
    templates = {"squid": "http_port {{ http_port }}\n",
                 "@redhat:/etc/squid/squid.conf": "http_port {{ http_port }}\nmax_filedescriptors {{ max_fd }}\n"}
    role_defaults = {"http_port": "3128", "max_fd": "16384"}
    family_only = {"max_fd": ["redhat"]}
    deb = _StateClient()
    res = await run_runbook(doc, deb, {"_family": "debian", "http_port": "3128", "max_fd": "4096",
                                       "_role_defaults": role_defaults, "_family_only": family_only},
                            templates=templates)
    assert not deb.calls
    assert "max_fd exist(s) only in the redhat file" in res.steps[0].error
    deb_ok = _StateClient()
    await run_runbook(doc, deb_ok, {"_family": "debian", "http_port": "3129", "max_fd": "16384",
                                    "_role_defaults": role_defaults, "_family_only": family_only}, templates=templates)
    vals = deb_ok.calls[0][1]["resources"][0]["values"]
    assert vals["http_port"] == "3129" and "_family_only" not in vals
    rh = _StateClient()
    await run_runbook(doc, rh, {"_family": "redhat", "http_port": "3128", "max_fd": "4096",
                                "_role_defaults": role_defaults, "_family_only": family_only}, templates=templates)
    assert rh.calls[0][1]["resources"][0]["values"]["max_fd"] == "4096"


async def test_a_pattern_destination_is_refused_not_written():
    """php-fpm on Debian wrote /etc/php/*/fpm/pool.d/www.conf literally (a directory named `*`) and read the same
    path back as "compliant" while the daemon kept its real file."""
    doc = rb("  - config_template:\n      template: php-fpm\n      dest: /etc/php/*/fpm/pool.d/www.conf\n")
    c = _StateClient()
    res = await run_runbook(doc, c, {"_family": "debian"}, templates={"php-fpm": "x\n"})
    assert not res.ok and "is a pattern, not a file" in res.steps[0].error and not c.calls


async def test_a_command_that_exits_non_zero_fails_the_step_and_stops_the_run():
    """`nginx -t` rc=1 used to count as `changed`; the run then restarted nginx with the broken file."""
    doc = rb("  - name: validate\n    command:\n      cmd: nginx -t\n"
             "  - name: restart\n    service:\n      name: nginx\n      state: restarted\n")
    client = FakeClient({"command": {"changed": True, "msg": "executed",
                                     "data": {"rc": 1, "stderr": "invalid number of arguments in \"user\""}}})
    res = await run_runbook(doc, client)
    assert [c[0] for c in client.calls] == ["command"]
    assert res.steps[0].status == "failed" and "exit code 1" in res.steps[0].error
    assert "invalid number of arguments" in res.steps[0].error


async def test_ignore_errors_accepts_a_non_zero_exit_deliberately():
    doc = rb("  - name: probe\n    command:\n      cmd: test -f /x\n    ignore_errors: true\n"
             "  - name: next\n    ping:\n")
    client = FakeClient({"command": {"changed": True, "data": {"rc": 1}}})
    res = await run_runbook(doc, client)
    assert [c[0] for c in client.calls] == ["command", "ping"]


class _AgentShapeClient(FakeClient):
    """The agent's real /state/apply answer: changes nested under `plan`, in check mode and in apply."""

    def __init__(self, action):
        super().__init__()
        self.action = action

    async def state_apply(self, body, check_mode):
        self.calls.append(("state_apply", body))
        return {"dry_run": check_mode, "generation": 0,
                "plan": {"changes": [{"type": "template_render", "path": "/etc/x", "action": self.action}],
                         "changed_count": 0 if self.action == "noop" else 1}}


async def test_config_template_reads_the_agents_plan_changes():
    """Measured on e2e-deb-1: a managed value edited by hand stayed "compliant", because the engine read a
    top-level `changes` the agent never sends. Drift must be seen in check mode, and a real change must notify."""
    doc = rb("  - name: render\n    config_template:\n      template: t\n      dest: /etc/x\n    notify: h\n",
             "  - name: h\n    command: reload\n")
    drift = await run_runbook(doc, _AgentShapeClient("update"), templates={"t": "x"}, check_mode=True)
    assert drift.changed and drift.steps[0].changed
    same = await run_runbook(doc, _AgentShapeClient("noop"), templates={"t": "x"}, check_mode=True)
    assert not same.changed
    applied = _AgentShapeClient("update")
    await run_runbook(doc, applied, templates={"t": "x"})
    assert ("command", {"cmd": "reload"}) in [(c[0], c[1]) for c in applied.calls if c[0] == "command"]


async def test_dotted_schema_keys_reach_the_template_nested_and_an_empty_dest_is_skipped_with_its_reason():
    doc = rb("  - config_template:\n      template: avahi\n      dest: /etc/avahi/avahi-daemon.conf\n"
             "  - config_template:\n      template: avahi\n      dest: ''\n")
    client = _StateClient()
    res = await run_runbook(doc, client, {"server.host_name": "box"}, templates={"avahi": "host-name={{ server.host_name }}"})
    values = client.calls[0][1]["resources"][0]["values"]
    assert values["server"] == {"host_name": "box"} and values["server.host_name"] == "box"
    assert res.steps[1].status == "skipped" and "no configuration file" in res.steps[1].error


async def test_a_template_is_never_written_over_a_file_it_does_not_render():
    """cups' template records /etc/cups/snmp.conf; the role's config path is cupsd.conf."""
    doc = rb("  - config_template:\n      template: cups\n      dest: /etc/cups/cupsd.conf\n")
    client = _StateClient()
    res = await run_runbook(doc, client, {}, templates={"cups": "x", "@target:cups": "/etc/cups/snmp.conf"})
    assert client.calls == []
    assert res.steps[0].status == "failed" and "renders /etc/cups/snmp.conf" in res.steps[0].error
    ok = _StateClient()
    await run_runbook(doc, ok, {}, templates={"cups": "x", "@target:cups": "/etc/cups/cupsd.conf"})
    assert ok.calls and ok.calls[0][0] == "state_apply"


def test_a_default_ending_in_a_backslash_stays_out_of_the_family_prelude():
    """gonja cannot lex "…\\\\" (exim4-redhat failed to parse on AlmaLinux); such a default is left to the template."""
    from bossman.api.config_templates import with_own_defaults

    body = with_own_defaults("x {{ a }}\n", {"a": {"default": "line \\"}, "b": {"default": "ok"}})
    assert "set a =" not in body and "set b = b | default(\"ok\", true)" in body
