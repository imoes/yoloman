"""Real, DB-backed tests for bossman.services.plan_engine — see
tests/conftest.py's db_session fixture. Uses a FakeAgentClient (no real
network) for call_tool/upload_file, the same test-seam pattern already
established for the poller (tests/test_poller.py) and the Go proxy's own
Manager.pullerFactory — every DB write here is real.
"""

import uuid
from tests.naming import owned_name

import pytest
from sqlalchemy import select

from bossman.db.models import Agent, PlanRun, PlanRunStep
from bossman.services.agent_client import AgentClientError
from bossman.services.plan_engine import run_plan
from bossman.services.plan_loader import PlanError, parse_plan


class FakeAgentClient:
    def __init__(self, tool_responses=None, tool_errors=None, upload_response=None, upload_error=None):
        self._tool_responses = tool_responses or {}
        self._tool_errors = tool_errors or {}
        self._upload_response = upload_response or {"path": "/staged/x", "bytes_written": 3}
        self._upload_error = upload_error
        self.tool_calls: list = []
        self.upload_calls: list = []

    async def call_tool(self, name, body):
        self.tool_calls.append((name, body))
        if name in self._tool_errors:
            raise self._tool_errors[name]
        return self._tool_responses.get(name, {"changed": True})

    async def upload_file(self, remote_name, data):
        self.upload_calls.append((remote_name, data))
        if self._upload_error:
            raise self._upload_error
        return self._upload_response


async def _make_agent(db_session) -> Agent:
    agent = Agent(name=owned_name("plan"), token="tok", mode="standalone", enrollment_state="enrolled")
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


def _plan(tmp_path, content):
    path = tmp_path / "plan.yaml"
    path.write_text(content)
    return parse_plan(path.read_bytes(), path)


async def _cleanup(db_session, agent, plan_run=None):
    if plan_run is not None:
        got = await db_session.get(PlanRun, plan_run.id)
        if got is not None:
            await db_session.delete(got)
            await db_session.flush()
    await db_session.delete(agent)
    await db_session.commit()


MODULE_PLAN = """
name: deploy_motd
params:
  message: { type: string, required: true }
steps:
  - name: write_motd
    copy:
      dest: /etc/motd
      content: "{{ message }}"
"""


async def test_run_plan_success_records_step_and_status(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, MODULE_PLAN)
    fake = FakeAgentClient(tool_responses={"copy": {"changed": True, "msg": "wrote"}})

    plan_run = await run_plan(
        db_session, agent, plan, host_vars={}, explicit_params={"message": "hello"}, dry_run=False, client=fake
    )

    assert plan_run.status == "succeeded"
    assert plan_run.params == {"message": "hello"}
    assert plan_run.plan_version == plan.version()
    assert fake.tool_calls == [("copy", {"dest": "/etc/motd", "content": "hello"})]

    steps = (
        await db_session.scalars(select(PlanRunStep).where(PlanRunStep.plan_run_id == plan_run.id))
    ).all()
    assert len(steps) == 1
    assert steps[0].module == "copy"
    assert steps[0].changed is True
    assert steps[0].http_status == 200
    assert steps[0].error is None

    await _cleanup(db_session, agent, plan_run)


async def test_run_plan_step_failure_aborts_and_marks_failed(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, MODULE_PLAN)
    fake = FakeAgentClient(tool_errors={"copy": AgentClientError("boom")})

    plan_run = await run_plan(
        db_session, agent, plan, host_vars={}, explicit_params={"message": "hi"}, dry_run=False, client=fake
    )

    assert plan_run.status == "failed"
    steps = (
        await db_session.scalars(select(PlanRunStep).where(PlanRunStep.plan_run_id == plan_run.id))
    ).all()
    assert len(steps) == 1
    assert "boom" in steps[0].error

    await _cleanup(db_session, agent, plan_run)


TWO_STEP_PLAN = """
name: two_steps
steps:
  - name: first
    on_failure: continue
    copy: {}
  - name: second
    file: {}
"""


async def test_run_plan_on_failure_continue_runs_remaining_steps(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, TWO_STEP_PLAN)
    fake = FakeAgentClient(tool_errors={"copy": AgentClientError("first failed")})

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert plan_run.status == "failed"  # a step failed, even though we continued past it
    assert [name for name, _ in fake.tool_calls] == ["copy", "file"]  # second step still ran

    await _cleanup(db_session, agent, plan_run)


ABORT_PLAN = """
name: abort_default
steps:
  - name: first
    copy: {}
  - name: second
    file: {}
"""


async def test_run_plan_on_failure_default_abort_stops_remaining_steps(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, ABORT_PLAN)
    fake = FakeAgentClient(tool_errors={"copy": AgentClientError("first failed")})

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert plan_run.status == "failed"
    assert [name for name, _ in fake.tool_calls] == ["copy"]  # second step never ran

    await _cleanup(db_session, agent, plan_run)


async def test_run_plan_dry_run_adds_dry_run_flag_to_module_body(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, MODULE_PLAN)
    fake = FakeAgentClient()

    plan_run = await run_plan(
        db_session, agent, plan, host_vars={}, explicit_params={"message": "hi"}, dry_run=True, client=fake
    )

    assert fake.tool_calls == [("copy", {"dest": "/etc/motd", "content": "hi", "dry_run": True})]
    assert plan_run.dry_run is True

    await _cleanup(db_session, agent, plan_run)


STEP_CHECK_MODE_PLAN = """
name: step_level_check_mode
steps:
  - name: validate
    check_mode: true
    command:
      cmd: "nginx -t"
"""


async def test_run_plan_step_level_check_mode_forces_dry_run_even_without_top_level(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, STEP_CHECK_MODE_PLAN)
    fake = FakeAgentClient()

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert fake.tool_calls == [("command", {"cmd": "nginx -t", "dry_run": True})]

    await _cleanup(db_session, agent, plan_run)


PIPELINE_PLAN = """
name: pipeline_plan
steps:
  - name: count
    pipeline:
      - ["ps", "aux"]
      - ["wc", "-l"]
"""


async def test_run_plan_pipeline_step_runs_for_real(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, PIPELINE_PLAN)
    fake = FakeAgentClient(tool_responses={"run_pipeline": {"stdout": "3\n"}})

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert fake.tool_calls == [("run_pipeline", {"stages": [["ps", "aux"], ["wc", "-l"]]})]
    assert plan_run.status == "succeeded"

    await _cleanup(db_session, agent, plan_run)


async def test_run_plan_pipeline_step_skipped_on_dry_run(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, PIPELINE_PLAN)
    fake = FakeAgentClient()

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=True, client=fake)

    assert fake.tool_calls == []  # never actually invoked

    await _cleanup(db_session, agent, plan_run)


UPLOAD_PLAN = """
name: upload_plan
params:
  vhost_name: { type: string, required: true }
steps:
  - name: upload_it
    upload:
      local_path: "files/{{ vhost_name }}.conf"
      remote_name: "{{ vhost_name }}.conf"
"""


async def test_run_plan_upload_step_reads_real_local_file(db_session, tmp_path):
    (tmp_path / "files").mkdir()
    (tmp_path / "files" / "web01.conf").write_bytes(b"server { listen 443; }")

    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, UPLOAD_PLAN)
    fake = FakeAgentClient()

    plan_run = await run_plan(
        db_session, agent, plan, host_vars={}, explicit_params={"vhost_name": "web01"}, dry_run=False, client=fake
    )

    assert fake.upload_calls == [("web01.conf", b"server { listen 443; }")]
    assert plan_run.status == "succeeded"

    await _cleanup(db_session, agent, plan_run)


async def test_run_plan_upload_step_skipped_on_dry_run(db_session, tmp_path):
    (tmp_path / "files").mkdir()
    (tmp_path / "files" / "web01.conf").write_bytes(b"content")

    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, UPLOAD_PLAN)
    fake = FakeAgentClient()

    plan_run = await run_plan(
        db_session, agent, plan, host_vars={}, explicit_params={"vhost_name": "web01"}, dry_run=True, client=fake
    )

    assert fake.upload_calls == []

    await _cleanup(db_session, agent, plan_run)


async def test_run_plan_missing_required_param_raises_before_any_row_created(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, MODULE_PLAN)  # requires "message"
    fake = FakeAgentClient()

    with pytest.raises(PlanError, match="missing required parameter"):
        await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    remaining = (await db_session.scalars(select(PlanRun).where(PlanRun.agent_id == agent.id))).all()
    assert remaining == []

    await db_session.delete(agent)
    await db_session.commit()


async def _steps(db_session, plan_run):
    rows = (
        await db_session.scalars(
            select(PlanRunStep).where(PlanRunStep.plan_run_id == plan_run.id).order_by(PlanRunStep.step_index)
        )
    ).all()
    return rows


REGISTER_WHEN_PLAN = """
name: register_when_plan
steps:
  - name: check_dir
    register: _dir_stat
    stat:
      path: /tmp/somewhere
  - name: create_if_missing
    when: not _dir_stat.data.exists
    file:
      path: /tmp/somewhere
      state: directory
"""


async def test_run_plan_register_feeds_later_when_true(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, REGISTER_WHEN_PLAN)
    fake = FakeAgentClient(tool_responses={"stat": {"changed": False, "data": {"exists": False}}})

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert plan_run.status == "succeeded"
    assert [name for name, _ in fake.tool_calls] == ["stat", "file"]  # the guarded step actually ran
    steps = await _steps(db_session, plan_run)
    assert len(steps) == 2
    assert steps[1].response_body is None or "skipped" not in steps[1].response_body

    await _cleanup(db_session, agent, plan_run)


async def test_run_plan_register_feeds_later_when_false_skips_without_agent_call(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, REGISTER_WHEN_PLAN)
    fake = FakeAgentClient(tool_responses={"stat": {"changed": False, "data": {"exists": True}}})

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert plan_run.status == "succeeded"
    assert [name for name, _ in fake.tool_calls] == ["stat"]  # "file" never called — when was false
    steps = await _steps(db_session, plan_run)
    assert len(steps) == 2
    assert steps[1].response_body == {"skipped": "when: not _dir_stat.data.exists evaluated false"}
    assert steps[1].error is None
    assert steps[1].changed is None

    await _cleanup(db_session, agent, plan_run)


WHEN_ERROR_PLAN = """
name: bad_when_plan
steps:
  - name: guarded
    when: a ===
    copy: {}
"""


async def test_run_plan_invalid_when_expression_is_recorded_as_step_error(db_session, tmp_path):
    """An unevaluable condition fails the step and never reaches the agent.

    The expression had to change with the contract, not the intent. `when:` used to be a
    hand-written whitelist grammar; it is now any Jinja2 expression in a SandboxedEnvironment
    with lenient undefined (services/when_eval.py). Under that contract the old fixture,
    `docker.proxy | default('x')`, is perfectly VALID — it yields 'x', the step runs, and the
    plan succeeds, so the test was asserting a rejection that had been deliberately removed.
    A genuine syntax error is what still must fail.
    """
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, WHEN_ERROR_PLAN)
    fake = FakeAgentClient()

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert plan_run.status == "failed"
    assert fake.tool_calls == []  # never reached the agent
    steps = await _steps(db_session, plan_run)
    assert len(steps) == 1
    assert "invalid when-expression" in steps[0].error

    await _cleanup(db_session, agent, plan_run)


async def test_run_plan_accepts_a_jinja_filter_in_when(db_session, tmp_path):
    """The other half of that contract change, so it is pinned rather than assumed.

    `x | default(...)` on a missing fact is the single most common Ansible `when:` idiom. It
    used to be rejected by the whitelist grammar; it must now evaluate — otherwise the pivot
    to Jinja semantics is only half done and nobody notices.
    """
    from bossman.services.when_eval import eval_when

    assert eval_when("docker.proxy | default('x')", {}) is True
    assert eval_when("docker.proxy | default('')", {}) is False, "falsy default stays falsy"
    assert eval_when("docker is defined", {}) is False
    assert eval_when("docker is defined", {"docker": {}}) is True


OS_DISPATCH_PLAN = """
name: os_dispatch_plan
chunks:
  - name: debian_packages
    os_family: [debian]
    steps:
      - name: install_debian
        apt:
          name: docker-ce
  - name: redhat_packages
    os_family: [redhat]
    steps:
      - name: install_redhat
        package:
          name: docker-ce
  - name: common
    steps:
      - name: enable_service
        service:
          name: docker
          state: started
"""


async def test_run_plan_os_dispatch_selects_matching_chunk_and_skips_others(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, OS_DISPATCH_PLAN)
    fake = FakeAgentClient(
        tool_responses={"setup": {"changed": False, "data": {"ansible_distribution": "Debian GNU/Linux"}}}
    )

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert plan_run.status == "succeeded"
    called = [name for name, _ in fake.tool_calls]
    assert called == ["setup", "apt", "service"]  # redhat's "package" tool never called
    steps = await _steps(db_session, plan_run)
    # setup + install_debian + skipped-redhat-chunk row + enable_service
    assert len(steps) == 4
    assert steps[0].step_name == "resolve OS family (setup)"
    assert steps[0].response_body == {"resolved_family": "debian"}
    skipped = steps[2]
    assert skipped.response_body["skipped"] == "os_family mismatch"
    assert skipped.response_body["expected"] == ["redhat"]
    assert skipped.response_body["actual"] == "debian"

    await _cleanup(db_session, agent, plan_run)


async def test_run_plan_os_dispatch_setup_failure_skips_all_restricted_chunks(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, OS_DISPATCH_PLAN)
    fake = FakeAgentClient(tool_errors={"setup": AgentClientError("agent unreachable")})

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert plan_run.status == "failed"
    # Neither os_family-restricted chunk runs without a resolved family;
    # the unconditional "common" chunk still does.
    called = [name for name, _ in fake.tool_calls]
    assert called == ["setup", "service"]
    steps = await _steps(db_session, plan_run)
    assert steps[0].error == "agent unreachable"
    assert steps[1].response_body["skipped"] == "os_family mismatch"
    assert steps[1].response_body["actual"] is None
    assert steps[2].response_body["skipped"] == "os_family mismatch"

    await _cleanup(db_session, agent, plan_run)


async def test_run_plan_os_dispatch_not_triggered_when_no_chunk_needs_it(db_session, tmp_path):
    """Plans with no os_family-restricted chunk must never pay for the
    extra setup() round trip — the whole point of only resolving the
    distribution family lazily."""
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, MODULE_PLAN)
    fake = FakeAgentClient()

    plan_run = await run_plan(
        db_session, agent, plan, host_vars={}, explicit_params={"message": "hi"}, dry_run=False, client=fake
    )

    assert "setup" not in [name for name, _ in fake.tool_calls]

    await _cleanup(db_session, agent, plan_run)


FINAL_HANDLER_PLAN = """
name: with_handler
steps:
  - name: install
    apt:
      name: docker-ce
final_handler:
  name: restart_docker
  service:
    name: docker
    state: restarted
"""


async def test_run_plan_final_handler_runs_when_something_changed(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, FINAL_HANDLER_PLAN)
    fake = FakeAgentClient(tool_responses={"apt": {"changed": True}, "service": {"changed": True}})

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert [name for name, _ in fake.tool_calls] == ["apt", "service"]
    steps = await _steps(db_session, plan_run)
    assert len(steps) == 2
    assert steps[1].step_name == "restart_docker"
    assert steps[1].changed is True

    await _cleanup(db_session, agent, plan_run)


async def test_run_plan_final_handler_does_not_run_when_nothing_changed(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, FINAL_HANDLER_PLAN)
    fake = FakeAgentClient(tool_responses={"apt": {"changed": False}})

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert [name for name, _ in fake.tool_calls] == ["apt"]  # "service" (the handler) never called
    steps = await _steps(db_session, plan_run)
    assert len(steps) == 1

    await _cleanup(db_session, agent, plan_run)


ABORT_WITH_HANDLER_PLAN = """
name: abort_with_handler
steps:
  - name: first
    apt:
      name: docker-ce
  - name: second
    file:
      path: /data1
final_handler:
  name: restart_docker
  service:
    name: docker
    state: restarted
"""


async def test_run_plan_final_handler_does_not_run_when_aborted(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, ABORT_WITH_HANDLER_PLAN)
    fake = FakeAgentClient(tool_responses={"apt": {"changed": True}}, tool_errors={"file": AgentClientError("boom")})

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert plan_run.status == "failed"
    assert [name for name, _ in fake.tool_calls] == ["apt", "file"]  # handler ("service") never called after abort
    steps = await _steps(db_session, plan_run)
    assert len(steps) == 2

    await _cleanup(db_session, agent, plan_run)


# --- Block NT-2: loop: support ------------------------------------------

LOOP_PLAN = """
name: loop_demo
steps:
  - name: install_each
    register: pkgs
    loop: [curl, git, htop]
    apt:
      name: "{{ item }}"
      state: present
"""


async def test_loop_runs_step_once_per_item_with_item_substituted(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, LOOP_PLAN)
    fake = FakeAgentClient(tool_responses={"apt": {"changed": True}})

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert plan_run.status == "succeeded"
    # one apt call per item, with {{ item }} substituted per iteration
    apt_bodies = [b for (n, b) in fake.tool_calls if n == "apt"]
    assert [b["name"] for b in apt_bodies] == ["curl", "git", "htop"]

    steps = (
        await db_session.scalars(
            select(PlanRunStep).where(PlanRunStep.plan_run_id == plan_run.id).order_by(PlanRunStep.step_index)
        )
    ).all()
    assert len(steps) == 3
    assert all(s.step_name.startswith("install_each [item=") for s in steps)

    await _cleanup(db_session, agent, plan_run)


LOOP_OVER_REGISTERED_PLAN = """
name: loop_registered
steps:
  - name: discover
    register: found
    command: {}
  - name: act_on_each
    loop: found.data.names
    file:
      path: "{{ item }}"
"""


async def test_loop_over_registered_result_list(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, LOOP_OVER_REGISTERED_PLAN)
    fake = FakeAgentClient(
        tool_responses={
            "command": {"changed": False, "data": {"names": ["/a", "/b"]}},
            "file": {"changed": True},
        }
    )

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert plan_run.status == "succeeded"
    file_bodies = [b for (n, b) in fake.tool_calls if n == "file"]
    assert [b["path"] for b in file_bodies] == ["/a", "/b"]

    await _cleanup(db_session, agent, plan_run)


LOOP_BAD_PLAN = """
name: loop_bad
steps:
  - name: nope
    loop: does.not.exist
    file: {}
"""


async def test_loop_undefined_path_is_a_recorded_failure(db_session, tmp_path):
    agent = await _make_agent(db_session)
    plan = _plan(tmp_path, LOOP_BAD_PLAN)
    fake = FakeAgentClient()

    plan_run = await run_plan(db_session, agent, plan, host_vars={}, explicit_params={}, dry_run=False, client=fake)

    assert plan_run.status == "failed"
    steps = (
        await db_session.scalars(select(PlanRunStep).where(PlanRunStep.plan_run_id == plan_run.id))
    ).all()
    assert len(steps) == 1
    assert "is not defined" in steps[0].error
    assert fake.tool_calls == []  # never dispatched

    await _cleanup(db_session, agent, plan_run)
