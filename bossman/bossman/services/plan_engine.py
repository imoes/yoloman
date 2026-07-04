"""Executes a Plan against one agent, step by step, persisting the
plan_runs/plan_run_steps audit trail (see docs/plan.md's Bossman plan,
section B.5) — the Ansible-replacement history the project's whole
Nordstern-UX design goal depends on: check_mode preview -> confirm ->
apply, with every step's request/response/changed/error recorded.

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
from bossman.services.plan_loader import Plan, PlanError, resolve_params, substitute


def _read_local_file(path: Path) -> bytes:
    return path.read_bytes()


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
    """Resolves plan parameters, then runs every step against client in
    order, recording each into plan_run_steps regardless of outcome.
    Raises PlanError only for a setup failure that happens *before* any
    step runs (missing required param, bad pattern) — once the PlanRun
    row exists, every failure is captured in the row/step data instead of
    raised, since a persisted partial audit trail is the whole point of a
    plan run, not an exception that leaves the caller with nothing."""
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

    any_step_failed = False

    for index, step in enumerate(plan.steps):
        effective_dry_run = dry_run or step.check_mode
        started_at = datetime.now(timezone.utc)
        request_body: dict[str, Any] = {}
        response_body: dict[str, Any] | None = None
        changed: bool | None = None
        http_status: int | None = None
        error: str | None = None
        module_label = step.module if step.kind == "module" else step.kind

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
            else:  # upload
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
        except (AgentClientError, PlanError, OSError) as exc:
            error = str(exc)

        session.add(
            PlanRunStep(
                plan_run_id=plan_run.id,
                step_index=index,
                step_name=step.name,
                module=module_label,
                request_body=request_body,
                response_body=response_body,
                changed=changed,
                http_status=http_status,
                error=error,
                started_at=started_at,
                finished_at=datetime.now(timezone.utc),
            )
        )
        await session.flush()

        if error is not None:
            any_step_failed = True
            if step.on_failure == "abort":
                break

    plan_run.status = "failed" if any_step_failed else "succeeded"
    plan_run.finished_at = datetime.now(timezone.utc)
    await session.commit()
    return plan_run
