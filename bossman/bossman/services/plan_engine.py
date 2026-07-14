"""Executes a Plan against one agent, chunk by chunk and step by step,
persisting the plan_runs/plan_run_steps audit trail (see docs/plan.md's
Bossman plan, section B.5 and the later chunked-plan-caching +
Ansible-ingestion plan) — the Ansible-replacement history the project's
whole Nordstern-UX design goal depends on: check_mode preview -> confirm
-> apply, with every step's request/response/changed/error recorded.

Framework-free (no FastAPI import), like services/enrollment.py and
services/poller.py, for the same reason: reachable from the REST API, the
MCP facade, and tests without duplicating logic.
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, PlanRun, PlanRunStep
from bossman.services.agent_client import AgentClient, AgentClientError
from bossman.services.plan_loader import Plan, PlanError, PlanStep, resolve_params, substitute
from bossman.services.when_eval import WhenError, eval_when


def _read_local_file(path: Path) -> bytes:
    return path.read_bytes()


def _distribution_family(name: str | None) -> str | None:
    """Normalizes the setup module's raw ansible_distribution fact (the
    host's /etc/os-release NAME field, e.g. "Debian GNU/Linux", "Ubuntu",
    "Red Hat Enterprise Linux") to the small canonical family id a
    chunk's `os_family` list matches against. Real Ansible does an
    equivalent distribution-to-family normalization internally; doing it
    here (not in the Go agent's setup module) keeps this a Bossman-side
    concern, scoped to what OS-dispatch actually needs."""
    if not name:
        return None
    lowered = name.lower()
    if "debian" in lowered:
        return "debian"
    if "ubuntu" in lowered:
        return "ubuntu"
    if any(k in lowered for k in ("red hat", "redhat", "centos", "rocky", "alma", "fedora")):
        return "redhat"
    return lowered.split()[0]


async def _execute_step(
    step: PlanStep,
    args: dict[str, Any],
    client: AgentClient,
    effective_dry_run: bool,
    plan: Plan,
    read_local_file,
    context: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any] | None, bool | None, int | None, str | None]:
    """Runs one step for real (or its check_mode/dry_run variant) and
    returns (request_body, response_body, changed, http_status, error) —
    pure with respect to the database; run_plan builds the PlanRunStep
    row from this. Never raises: AgentClientError/PlanError/OSError are
    caught and folded into `error`, since a persisted partial audit trail
    is the point of a plan run, not an exception that discards it."""
    request_body: dict[str, Any] = {}
    response_body: dict[str, Any] | None = None
    changed: bool | None = None
    http_status: int | None = None
    error: str | None = None

    try:
        if step.kind == "module":
            request_body = substitute(step.body, args)
            if effective_dry_run:
                request_body = {**request_body, "dry_run": True}
            response_body = await client.call_tool(step.module, request_body)
            changed = response_body.get("changed")
            http_status = 200
        elif step.kind == "pipeline":
            request_body = {"stages": substitute(step.pipeline, args)}
            if effective_dry_run:
                response_body = {"skipped": "dry_run: pipeline steps have no preview mode"}
            else:
                response_body = await client.call_tool("run_pipeline", request_body)
                changed = True
                http_status = 200
        elif step.kind == "upload":
            local_path = substitute(step.upload_local_path, args)
            remote_name = substitute(step.upload_remote_name, args)
            request_body = {"local_path": local_path, "remote_name": remote_name}
            if effective_dry_run:
                response_body = {"skipped": "dry_run: upload steps have no preview mode"}
            else:
                data = read_local_file(plan.source_path.parent / local_path)
                response_body = await client.upload_file(remote_name, data)
                changed = True
                http_status = 200
        # Controller-side kinds: evaluated here against the plan's variable
        # context, never sent to the host (same posture as Ansible's
        # set_fact/debug/assert action plugins). Always run, even in dry_run —
        # they mutate/inspect plan state, not the host.
        elif step.kind == "set_fact":
            facts = {k: substitute(v, args) for k, v in (step.set_fact or {}).items()}
            request_body = facts
            response_body = {"ansible_facts": facts}
            changed = False
        elif step.kind == "debug":
            if step.debug_var is not None:
                rendered = _resolve_dotted(step.debug_var, context)
            else:
                rendered = substitute(step.debug_msg or "", args)
            response_body = {"msg": rendered}
            changed = False
        elif step.kind == "assert":
            failed = None
            for cond in step.assert_that or []:
                if not eval_when(cond, context):
                    failed = cond
                    break
            if failed is not None:
                error = step.assert_fail_msg or f"assertion failed: {failed}"
            else:
                response_body = {"msg": step.assert_success_msg or "All assertions passed"}
                changed = False
    except (AgentClientError, PlanError, OSError, WhenError) as exc:
        error = str(exc)

    return request_body, response_body, changed, http_status, error


def _step_row(
    plan_run_id,
    index: int,
    name: str,
    module_label: str | None,
    request_body: dict[str, Any],
    response_body: dict[str, Any] | None,
    changed: bool | None,
    http_status: int | None,
    error: str | None,
    started_at: datetime,
) -> PlanRunStep:
    return PlanRunStep(
        plan_run_id=plan_run_id,
        step_index=index,
        step_name=name,
        module=module_label,
        request_body=request_body,
        response_body=response_body,
        changed=changed,
        http_status=http_status,
        error=error,
        started_at=started_at,
        finished_at=datetime.now(timezone.utc),
    )


def _resolve_dotted(path: str, context: dict[str, Any]) -> Any:
    """Look up a dotted path (e.g. "reg.stdout") in the run context; returns
    the path string unchanged if it does not resolve, mirroring a best-effort
    debug var dump rather than failing the step."""
    value: Any = context
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            return path
        value = value[part]
    return value


def _resolve_loop_items(step: PlanStep, context: dict[str, Any]) -> list[Any]:
    """Resolve a step's loop into the list of items to iterate. Returns
    [None] when the step has no loop (a single iteration, no `item` in
    scope). A literal list is used as-is; a string is a dotted path (a param
    or registered result) that must resolve to a list at run time."""
    if step.loop is None:
        return [None]
    if isinstance(step.loop, list):
        return list(step.loop)
    value: Any = context
    for part in step.loop.split("."):
        if not isinstance(value, dict) or part not in value:
            raise PlanError(f"loop: {step.loop!r} is not defined")
        value = value[part]
    if not isinstance(value, list):
        raise PlanError(f"loop: {step.loop!r} did not resolve to a list (got {type(value).__name__})")
    return value


async def run_plan(
    session: AsyncSession,
    agent: Agent,
    plan: Plan,
    host_vars: dict[str, Any],
    explicit_params: dict[str, Any],
    dry_run: bool,
    client: AgentClient,
    requested_by: str | None = None,
    read_local_file=_read_local_file,
) -> PlanRun:
    """Resolves plan parameters, then runs every chunk/step against client
    in order, recording each into plan_run_steps regardless of outcome.
    Raises PlanError only for a setup failure that happens *before* any
    step runs (missing required param, bad pattern) — once the PlanRun
    row exists, every failure is captured in the row/step data instead of
    raised, since a persisted partial audit trail is the whole point of a
    plan run, not an exception that leaves the caller with nothing.

    Chunk-level semantics (see docs/plan.md's Ansible-ingestion plan):
    - A chunk with `os_family` set is skipped entirely (one summary row,
      no per-step rows) if the host's distribution family — resolved via
      one `setup` call, only when at least one chunk actually needs it —
      doesn't match. This is the OS-dispatch equivalent of Ansible's
      `include_tasks: "{{ ansible_distribution }}.packages.yml"`.
    - A step's `when:` is evaluated against a context combining resolved
      params and every prior step's `register`ed result (shared
      namespace, like Ansible's own variables) via services.when_eval's
      small, non-Turing-complete grammar. A false `when` skips just that
      step (one row, no agent call) and is never itself a failure.
    - `plan.final_handler`, if set, runs once at the end — only if the
      run wasn't aborted early and at least one step reported
      `changed: True` — the normalized form of an Ansible notify/handler.
    """
    args = resolve_params(plan, host_vars, explicit_params)

    plan_run = PlanRun(
        plan_name=plan.name,
        plan_version=plan.version(),
        agent_id=agent.id,
        params=args,
        dry_run=dry_run,
        status="running",
        requested_by=requested_by,
    )
    session.add(plan_run)
    await session.flush()

    context: dict[str, Any] = dict(args)
    any_step_failed = False
    any_step_changed = False
    aborted = False
    index = 0

    if any(c.os_family is not None for c in plan.chunks):
        started_at = datetime.now(timezone.utc)
        family, setup_error = await _resolve_distribution_family_from_agent(client)
        # Always recorded, success or failure — an OS-dispatch decision is
        # as much a part of the audit trail as any other step, not just
        # its failures.
        session.add(
            _step_row(
                plan_run.id,
                index,
                "resolve OS family (setup)",
                "setup",
                {},
                None if setup_error else {"resolved_family": family},
                None,
                None,
                setup_error,
                started_at,
            )
        )
        await session.flush()
        index += 1
        if setup_error is not None:
            any_step_failed = True
    else:
        family = None

    for chunk in plan.chunks:
        if aborted:
            break

        if chunk.os_family is not None and (family is None or family not in chunk.os_family):
            session.add(
                _step_row(
                    plan_run.id,
                    index,
                    f"{chunk.name} (chunk)",
                    None,
                    {},
                    {"skipped": "os_family mismatch", "expected": chunk.os_family, "actual": family},
                    None,
                    None,
                    None,
                    datetime.now(timezone.utc),
                )
            )
            await session.flush()
            index += 1
            continue

        for step in chunk.steps:
            module_label = step.module if step.kind == "module" else step.kind

            # Resolve the loop (a single [None] iteration when there is no
            # loop). A loop that references an undefined/non-list path is a
            # step failure recorded like any other, honoring on_failure.
            try:
                loop_items = _resolve_loop_items(step, context)
            except PlanError as exc:
                session.add(_step_row(plan_run.id, index, step.name, module_label, {}, None, None, None, str(exc), datetime.now(timezone.utc)))
                await session.flush()
                index += 1
                any_step_failed = True
                if step.on_failure == "abort":
                    aborted = True
                    break
                continue

            # Aggregation across iterations (only meaningful when looping).
            iter_responses: list[dict[str, Any]] = []
            iter_changed_any = False
            last_response: dict[str, Any] | None = None
            had_response = False

            for loop_item in loop_items:
                started_at = datetime.now(timezone.utc)
                if step.loop is None:
                    iter_context, iter_args, row_name = context, args, step.name
                else:
                    # Each iteration exposes the element as `item` for both
                    # when: evaluation and {{ item }} substitution.
                    iter_context = {**context, "item": loop_item}
                    iter_args = {**args, "item": loop_item}
                    row_name = f"{step.name} [item={loop_item!r}]"

                if step.when is not None:
                    try:
                        should_run = eval_when(step.when, iter_context)
                    except WhenError as exc:
                        session.add(_step_row(plan_run.id, index, row_name, module_label, {}, None, None, None, str(exc), started_at))
                        await session.flush()
                        index += 1
                        any_step_failed = True
                        if step.on_failure == "abort":
                            aborted = True
                        break
                    if not should_run:
                        session.add(
                            _step_row(plan_run.id, index, row_name, module_label, {}, {"skipped": f"when: {step.when} evaluated false"}, None, None, None, started_at)
                        )
                        await session.flush()
                        index += 1
                        continue

                effective_dry_run = dry_run or step.check_mode
                request_body, response_body, changed, http_status, error = await _execute_step(
                    step, iter_args, client, effective_dry_run, plan, read_local_file, iter_context
                )

                # Ansible's ansible_facts return convention: ANY step whose
                # response carries `ansible_facts` publishes them into the run's
                # namespace for every later step — both `context` (when:) and
                # `args` (\{\{ }}). This is how set_fact sets vars without a
                # register, and how setup/package_facts' gathered facts flow.
                if error is None and isinstance(response_body, dict):
                    facts = response_body.get("ansible_facts")
                    if isinstance(facts, dict):
                        context.update(facts)
                        args.update(facts)

                session.add(
                    _step_row(plan_run.id, index, row_name, module_label, request_body, response_body, changed, http_status, error, started_at)
                )
                await session.flush()
                index += 1

                if response_body is not None:
                    had_response = True
                    last_response = response_body
                    iter_responses.append(response_body)
                if changed:
                    any_step_changed = True
                    iter_changed_any = True
                if error is not None:
                    any_step_failed = True
                    if step.on_failure == "abort":
                        aborted = True
                    break  # stop iterating this step's remaining items

            # Register once per step: the single response when not looping;
            # Ansible-style {results: [...]} aggregate when looping.
            if step.register and had_response:
                if step.loop is None:
                    context[step.register] = last_response
                else:
                    context[step.register] = {"results": iter_responses, "changed": iter_changed_any}

            if aborted:
                break

    if not aborted and any_step_changed and plan.final_handler is not None:
        handler = plan.final_handler
        started_at = datetime.now(timezone.utc)
        effective_dry_run = dry_run or handler.check_mode
        request_body, response_body, changed, http_status, error = await _execute_step(
            handler, args, client, effective_dry_run, plan, read_local_file, context
        )
        module_label = handler.module if handler.kind == "module" else handler.kind
        session.add(
            _step_row(plan_run.id, index, handler.name, module_label, request_body, response_body, changed, http_status, error, started_at)
        )
        await session.flush()
        if error is not None:
            any_step_failed = True

    plan_run.status = "failed" if any_step_failed else "succeeded"
    plan_run.finished_at = datetime.now(timezone.utc)
    await session.commit()
    return plan_run


async def _resolve_distribution_family_from_agent(client: AgentClient) -> tuple[str | None, str | None]:
    """Calls the agent's `setup` tool once and returns (family, error) —
    error is set (family is None) if the call itself failed; family may
    still legitimately be None if the agent had no distribution fact to
    report, which is not an error."""
    try:
        facts = await client.call_tool("setup", {})
    except AgentClientError as exc:
        return None, str(exc)
    data = facts.get("data") if isinstance(facts, dict) else None
    # Prefer the native yoloman_ fact; fall back to the ansible_ compat alias
    # for agents that predate the rename.
    raw_distribution = None
    if isinstance(data, dict):
        raw_distribution = data.get("yoloman_distribution") or data.get("ansible_distribution")
    return _distribution_family(raw_distribution), None
