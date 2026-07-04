"""Real, DB-backed tests for bossman.services.plan_engine — see
tests/conftest.py's db_session fixture. Uses a FakeAgentClient (no real
network) for call_tool/upload_file, the same test-seam pattern already
established for the poller (tests/test_poller.py) and the Go proxy's own
Manager.pullerFactory — every DB write here is real.
"""

import uuid

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
    agent = Agent(name=f"plan-{uuid.uuid4().hex[:8]}", token="tok", mode="standalone", enrollment_state="enrolled")
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
    ansible.builtin.copy:
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
    ansible.builtin.copy: {}
  - name: second
    ansible.builtin.file: {}
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
    ansible.builtin.copy: {}
  - name: second
    ansible.builtin.file: {}
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
    ansible.builtin.command:
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
