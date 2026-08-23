"""Check library REST surface (Block G9): list the checks in checks_dir and
read one check's metadata + Starlark source. Read-only for now; assigning a
check to a host/group/OU (with per-scope thresholds) rides the existing
orchestration/GPO layer and the host page (Block G9-P2)."""

from __future__ import annotations

from typing import Any
from uuid import UUID

import yaml
import asyncio

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent, CheckAssignment
from bossman.db.session import get_session
from bossman.services import check_platform, checks_library
from bossman.services.auth import Identity, user_can_manage_agent
from bossman.services.check_assignments import resolve_host_checks
from bossman.services.module_library import ModuleLibraryError

router = APIRouter()

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


@router.get("/api/v1/checks")
async def list_checks(
    settings: Settings = Depends(get_settings), _identity=Depends(get_current_identity)
) -> dict[str, Any]:
    """Every check in the library: name, short_description, source
    (translated|custom), and its options (the argspec the host-page config
    form renders)."""
    return {"checks": checks_library.list_checks(settings.checks_dir)}


@router.get("/api/v1/checks/{name}")
async def get_check(
    name: str, settings: Settings = Depends(get_settings), _identity=Depends(get_current_identity)
) -> dict[str, Any]:
    """One check's stored metadata + Starlark source."""
    try:
        return checks_library.load_check(settings.checks_dir, name)
    except ModuleLibraryError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


# ── Assignments: a check bound to a host / group / OU (Block G9-P2) ────────


def _assignment_out(a: CheckAssignment) -> dict[str, Any]:
    return {
        "id": str(a.id),
        "check_name": a.check_name,
        "scope_type": a.scope_type,
        "ou_id": str(a.ou_id) if a.ou_id else None,
        "agent_id": str(a.agent_id) if a.agent_id else None,
        "host_group_id": str(a.host_group_id) if a.host_group_id else None,
        "parameters": a.parameters or {},
        "conditions": a.conditions or {},
        "enabled": a.enabled,
        "source": a.source,
    }


@router.get("/api/v1/agents/{agent_id}/checks")
async def effective_host_checks(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """The checks that effectively apply to this host — resolved GPO-style
    from every assignment reaching it (host + groups + OU ancestry), with
    merged params and the winning scope. Each entry is enriched with the
    check's short_description + options (the config form's argspec)."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="no such agent")
    effective = await resolve_host_checks(session, agent)
    catalog = {c["name"]: c for c in checks_library.list_checks(settings.checks_dir)}
    out = []
    for ec in effective:
        meta = catalog.get(ec.check_name, {})
        out.append({
            **ec.to_dict(),
            "short_description": meta.get("short_description", ""),
            "options": meta.get("options", {}),
            "in_library": ec.check_name in catalog,
        })
    return {"agent_id": str(agent_id), "checks": out}


@router.get("/api/v1/check-assignments")
async def list_assignments(
    agent_id: UUID | None = None,
    ou_id: UUID | None = None,
    host_group_id: UUID | None = None,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Raw check assignments, optionally filtered to one scope target — the
    direct assignments on a host / group / OU (not the resolved inheritance;
    use GET /agents/{id}/checks for the effective set)."""
    stmt = select(CheckAssignment).where(CheckAssignment.tenant_id == DEFAULT_TENANT_ID)
    if agent_id is not None:
        stmt = stmt.where(CheckAssignment.agent_id == agent_id)
    if ou_id is not None:
        stmt = stmt.where(CheckAssignment.ou_id == ou_id)
    if host_group_id is not None:
        stmt = stmt.where(CheckAssignment.host_group_id == host_group_id)
    rows = (await session.scalars(stmt.order_by(CheckAssignment.check_name))).all()
    return {"assignments": [_assignment_out(a) for a in rows]}


class CreateAssignmentRequest(BaseModel):
    check_name: str
    scope_type: str  # ou | group | host
    ou_id: UUID | None = None
    agent_id: UUID | None = None
    host_group_id: UUID | None = None
    parameters: dict[str, Any] = {}
    source: str = "manual"
    # Checkmk match conditions (services/rule_conditions): host_tags / labels /
    # os / folder / host+service name; empty = applies wherever the scope reaches.
    conditions: dict[str, Any] = {}


@router.post("/api/v1/check-assignments")
async def create_assignment(
    body: CreateAssignmentRequest,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity: Identity = Depends(get_current_identity),
) -> dict[str, Any]:
    """Assign a check to a host, group, or OU with per-scope parameters. A
    host-scoped assignment needs manage rights on that host; group/OU-scoped
    assignments are admin-only (they affect many hosts). The check must exist
    in the library."""
    if body.scope_type not in ("ou", "group", "host"):
        raise HTTPException(status_code=422, detail="scope_type must be one of: ou, group, host")
    scope_id = {"ou": body.ou_id, "group": body.host_group_id, "host": body.agent_id}[body.scope_type]
    if scope_id is None:
        raise HTTPException(status_code=422, detail=f"scope_type={body.scope_type} requires the matching id")
    try:
        checks_library.load_check(settings.checks_dir, body.check_name)
    except ModuleLibraryError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    # ACL: host scope → manage that host; group/OU → admin (broad blast radius).
    if body.scope_type == "host":
        if not await user_can_manage_agent(session, identity, body.agent_id):
            raise HTTPException(status_code=403, detail="not authorized to manage this host")
    else:
        if not (identity.kind == "user" and identity.role == "admin"):
            raise HTTPException(status_code=403, detail="group/OU assignments are admin-only")

    a = CheckAssignment(
        tenant_id=DEFAULT_TENANT_ID,
        check_name=body.check_name,
        scope_type=body.scope_type,
        ou_id=body.ou_id if body.scope_type == "ou" else None,
        agent_id=body.agent_id if body.scope_type == "host" else None,
        host_group_id=body.host_group_id if body.scope_type == "group" else None,
        parameters=body.parameters or {},
        conditions=body.conditions or {},
        source=body.source if body.source in ("manual", "autodiscovered", "ai") else "manual",
        created_by=identity.name,
    )
    session.add(a)
    await session.commit()
    return _assignment_out(a)


class UpdateAssignmentRequest(BaseModel):
    parameters: dict[str, Any]


@router.patch("/api/v1/check-assignments/{assignment_id}")
async def update_assignment(
    assignment_id: UUID,
    body: UpdateAssignmentRequest,
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> dict[str, Any]:
    """Edit an existing assignment's parameters in place (same scope/check),
    so a service check can be reconfigured without delete+recreate. Same ACL
    as delete: host scope → manage that host; group/OU → admin."""
    a = await session.get(CheckAssignment, assignment_id)
    if a is None:
        raise HTTPException(status_code=404, detail="no such assignment")
    if a.scope_type == "host":
        if not await user_can_manage_agent(session, identity, a.agent_id):
            raise HTTPException(status_code=403, detail="not authorized to manage this host")
    elif not (identity.kind == "user" and identity.role == "admin"):
        raise HTTPException(status_code=403, detail="group/OU assignments are admin-only")
    a.parameters = body.parameters or {}
    await session.commit()
    return _assignment_out(a)


@router.delete("/api/v1/check-assignments/{assignment_id}", status_code=204)
async def delete_assignment(
    assignment_id: UUID,
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> None:
    a = await session.get(CheckAssignment, assignment_id)
    if a is None:
        raise HTTPException(status_code=404, detail="no such assignment")
    if a.scope_type == "host":
        if not await user_can_manage_agent(session, identity, a.agent_id):
            raise HTTPException(status_code=403, detail="not authorized to manage this host")
    elif not (identity.kind == "user" and identity.role == "admin"):
        raise HTTPException(status_code=403, detail="group/OU assignments are admin-only")
    # A host-scoped assignment that came from discovery is one half of a pair: the
    # discovered_services row says `monitored` BECAUSE this assignment exists. Deleting
    # only the assignment left the row claiming "monitored" while the host had no
    # assigned check — two views of the same host contradicting each other. Reset the
    # row to `undecided` (the service is still on the host, just not monitored), which
    # is exactly what apply_discovery's `remove` does.
    if a.scope_type == "host" and a.agent_id and (a.source or "") == "autodiscovered":
        from bossman.services import discovery_lifecycle

        item = str((a.parameters or {}).get("item") or "")
        row = await _discovered_row(session, a.agent_id, a.check_name, item)
        if row is not None and row.state == discovery_lifecycle.STATE_MONITORED:
            row.state = discovery_lifecycle.STATE_UNDECIDED
    await session.delete(a)
    await session.commit()


# ── Auto-discovery: run checks in _discover mode on the host (Block G9-P3c) ─


async def _agent_with_address(session: AsyncSession, agent_id: UUID) -> Agent:
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="no such agent")
    if not agent.address:
        raise HTTPException(status_code=422, detail="agent has no address to reach")
    return agent


def _check_datasource(star: str) -> str:
    """Bossman-side datasource classifier — now centralised in checks_library
    (kept as a thin alias so existing call sites don't churn)."""
    return checks_library.check_datasource(star)


def _is_unrunnable_source(star: str) -> bool:
    """True if the check can't get real data from OUR agent (Checkmk-internal
    path / cmk CLI / fabricated echo section). Shared with the catalog's
    `runnable` flag so discovery and the picker agree on what to exclude."""
    return not checks_library.check_runnable(star)


def _load_candidate_checks(
    settings: Settings, names: list[str] | None, datasource: str = "agent", platform: str = "linux"
) -> list[dict[str, Any]]:
    """Load the checks to run discovery for, each as {name, star, sidecar,
    sidecar_format, options, short_description}.

    Checkmk-style relevance pre-filter (see cmk .../discovery/_discover/
    services.py `_find_host_plugins`): don't run every check in the library —
    only those whose DATA SOURCE the host actually has. A plain agent host
    never satisfies the 600+ SNMP checks, so running them was pure waste + the
    reason discovery surfaced far too many/irrelevant candidates. When explicit
    `names` are given (a targeted re-scan) the datasource filter is skipped."""
    from pathlib import Path

    catalog = {c["name"]: c for c in checks_library.list_checks(settings.checks_dir)}
    wanted = names if names else list(catalog)
    out: list[dict[str, Any]] = []
    for name in wanted:
        entry = catalog.get(name)
        if not entry:
            continue
        meta_path, star_path = checks_library.check_paths(settings.checks_dir, name)
        try:
            star = star_path.read_text(encoding="utf-8")
            sidecar = Path(meta_path).read_text(encoding="utf-8")
        except OSError:
            continue
        # check_paths returns whichever sidecar exists, so the format follows the extension.
        # Relevance pre-filter by data source (skipped for an explicit re-scan).
        if not names and _check_datasource(star) != datasource:
            continue
        # Never a candidate: reads Checkmk-site/agent internals or fakes its
        # section — no real data on our agent (drops bi_aggregation, mssql_instance,
        # lsi_array, safenet/skype `cmk`, echo-simulated lgp_info, …). Honoured
        # even for an explicit re-scan — these genuinely can't run here.
        if _is_unrunnable_source(star):
            continue
        # Checkmk's actual discovery gate, ported: a check whose sections only
        # ever come from ANOTHER platform's agent, a Windows plugin or a special
        # agent can never be satisfied here — drop it before the host ever runs
        # it. This is what kept offering aix_hacmp_services, citrix_sessions and
        # vms_cpu on a Debian VM: those checks fabricate their section, so no
        # behavioural probe could tell they don't apply. Honoured on an explicit
        # re-scan too — the platform doesn't change because someone re-scans.
        if check_platform.verdict(name, platform, settings.checkmk_sections_path, datasource) == "impossible":
            continue
        # The agent registers the tool under its fqcn, so parse it out of the sidecar and pass it through
        # (call_tool needs it). Sidecars are YAML — the NestedText branch is gone with the dependency:
        # measured, 0 `.nt` files against 1431 `.yaml` in the tree.
        fqcn = name
        try:
            meta = yaml.safe_load(sidecar)
            if isinstance(meta, dict) and meta.get("fqcn"):
                fqcn = str(meta["fqcn"])
        except yaml.YAMLError:
            pass
        out.append({
            "name": name, "fqcn": fqcn, "star": star, "sidecar": sidecar, "sidecar_format": meta_format,
            "options": entry.get("options", {}), "short_description": entry.get("short_description", ""),
        })
    return out


async def _run_discovery_core(
    session, settings, client_factory, agent, names, datasource, checks, progress=None
) -> dict[str, Any]:
    """The discovery run itself, returning the same `out` dict the endpoint used to return directly.

    Factored out so it can run inside a background task (for the progress bar) with its own session,
    while `run_check_discovery`'s `progress` callback drives the percent. A container step counts as one
    unit of work too, so the bar reaches 100 only after it."""
    from bossman.services.discovery import discover_containers, run_check_discovery
    from bossman.services import discovery_lifecycle

    client = client_factory(agent, settings)
    proposals = await run_check_discovery(client, checks, progress=progress)

    # Containers: only on a full agent run (a device has none; a targeted check_names re-scan asked for
    # specific checks, not containers).
    if datasource == "agent" and not names:
        proposals.append(await discover_containers(client))
        if progress is not None:
            progress()

    out: dict[str, Any] = {
        "agent_id": str(agent.id),
        "candidates": len(checks),
        "proposals": [p.to_dict() for p in proposals],
    }
    if names:
        out["reconciled"] = False
        return out

    transitions = await discovery_lifecycle.reconcile(session, agent, proposals)
    host_labels: dict[str, str] = {}
    for p in proposals:
        host_labels.update(p.host_labels or {})
    label_counts = await discovery_lifecycle.reconcile_host_labels(session, agent, host_labels)
    await session.commit()
    out["reconciled"] = True
    out["transitions"] = transitions.counts()
    out["vanished"] = [{"check_name": r.check_name, "item": r.item} for r in transitions.vanished]
    out["host_labels"] = label_counts
    return out


async def _discovery_task(session_factory, settings, client_factory, agent_id, names, datasource, checks, job_id, registry):
    """Background driver: own session (the request's is long gone), reports progress, records the
    result or the failure on the job. Never raises — a discovery failure is the job's error, polled by
    the UI, not an unhandled task exception."""
    from bossman.services.agent_client import AgentClientError

    try:
        async with session_factory() as session:
            agent = await session.get(Agent, agent_id)
            if agent is None:
                await registry.fail(job_id, "agent no longer exists")
                return
            out = await _run_discovery_core(
                session, settings, client_factory, agent, names, datasource, checks,
                progress=lambda: registry.bump(job_id),
            )
        await registry.finish(job_id, out)
    except AgentClientError as exc:
        await registry.fail(job_id, f"agent unreachable: {exc}")
    except Exception as exc:  # noqa: BLE001 — surfaced to the UI via the job, not swallowed silently
        await registry.fail(job_id, str(exc))


@router.post("/api/v1/agents/{agent_id}/discover")
async def discover_checks(
    agent_id: UUID,
    request: Request,
    body: dict[str, Any] | None = None,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity: Identity = Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Start Checkmk-style auto-discovery as a BACKGROUND JOB and return its id + total.

    Discovery probes ~1400 checks and takes seconds, so it no longer blocks the request: it returns
    {job_id, total, candidates} immediately, and the UI polls GET .../discover/progress/{job_id} for a
    percent bar and, on completion, the result (proposals + transitions — Checkmk's QualifiedDiscovery,
    which reconciles against what was found last time so a LOST service is distinguishable from one that
    never existed). It still decides nothing: new → undecided, missing → vanished; accept/ignore via
    .../discover/apply.

    Optional body: {check_names:[...]} scopes the run (no reconcile — it saw only a slice), {datasource:
    'snmp'} for a device."""
    if not await user_can_manage_agent(session, identity, agent_id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
    agent = await _agent_with_address(session, agent_id)
    names = (body or {}).get("check_names")
    datasource = (body or {}).get("datasource") or "agent"
    platform = check_platform.platform_of(agent.facts or {})
    checks = _load_candidate_checks(settings, names, datasource, platform)

    # total work units for the percent bar: one per candidate check, plus one for the container step on
    # a full agent run.
    total = len(checks) + (1 if (datasource == "agent" and not names) else 0)
    registry = request.app.state.discovery_jobs
    job = await registry.create(total)
    # Fire-and-forget: the task owns its own session and reports onto the job. Keep a reference so the
    # task is not garbage-collected mid-run (asyncio only holds a weak ref).
    task = asyncio.create_task(
        _discovery_task(
            request.app.state.session_factory, settings, client_factory,
            agent.id, names, datasource, checks, job.id, registry,
        )
    )
    _DISCOVERY_TASKS.add(task)
    task.add_done_callback(_DISCOVERY_TASKS.discard)
    return {"job_id": job.id, "total": total, "candidates": len(checks)}


# Strong references to in-flight discovery tasks (asyncio keeps only weak refs, so without this a task
# could be collected before it finishes).
_DISCOVERY_TASKS: set[asyncio.Task] = set()


@router.get("/api/v1/agents/{agent_id}/discover/progress/{job_id}")
async def discover_progress(
    agent_id: UUID,
    job_id: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> dict[str, Any]:
    """Poll a discovery job's progress: {total, completed, percent, done, result?/error?}.

    The result (host services) is only readable by someone who may manage the host, same as starting the
    discovery."""
    if not await user_can_manage_agent(session, identity, agent_id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
    job = request.app.state.discovery_jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="no such discovery job (it may have expired or the process restarted)")
    return job.snapshot()


@router.post("/api/v1/agents/{agent_id}/discover/apply")
async def apply_discovery(
    agent_id: UUID,
    body: dict[str, Any],
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    client_factory=Depends(get_client_factory),
    identity: Identity = Depends(get_current_identity),
) -> dict[str, Any]:
    """Decide what to do with discovered services.

    body {accept|ignore|remove: [{check_name, item?, parameters?}, ...]}
      accept  -> discovered_services.state='monitored' + a host-scoped CheckAssignment
      ignore  -> state='ignored'; later runs stop offering it (the decision is REMEMBERED,
                 which is the whole point — previously, not applying left no trace)
      remove  -> drop the assignment and reset the row to 'undecided'

    `assign` is still accepted as an alias for `accept`, so the existing UI and the AI
    chat tool keep working unchanged.

    IDEMPOTENT: accepting twice does not create a second assignment. The old version
    inserted unconditionally, so a repeated apply silently duplicated every row —
    Checkmk's set_autochecks rewrites the host's set and de-duplicates by identity
    (cmk/checkengine/discovery/_autochecks.py)."""
    from bossman.services import discovery_lifecycle

    if not await user_can_manage_agent(session, identity, agent_id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="no such agent")

    counts = {"accepted": 0, "ignored": 0, "removed": 0}
    specs = [
        *(("accept", s) for s in (body.get("accept") or []) + (body.get("assign") or [])),
        *(("ignore", s) for s in (body.get("ignore") or [])),
        *(("remove", s) for s in (body.get("remove") or [])),
    ]
    for verb, spec in specs:
        check_name = spec.get("check_name")
        if not check_name:
            continue
        item = str(spec.get("item") or "")
        row = await _discovered_row(session, agent_id, check_name, item)

        if verb == "ignore":
            if row is not None:
                row.state = discovery_lifecycle.STATE_IGNORED
            await _drop_assignment(session, agent_id, check_name, item)
            counts["ignored"] += 1
            continue

        if verb == "remove":
            # Removing a service that is STILL on the host means "stop monitoring it,
            # offer it again next run" → undecided. Removing a VANISHED one means
            # "it is gone, stop tracking it": leaving it as `undecided` would claim
            # discovery found it while this very run did not — a contradiction, and it
            # would resurface as "new". So drop the row, which is what
            # discovery_lifecycle does for remove_vanished_services.
            if row is not None:
                if row.state == discovery_lifecycle.STATE_VANISHED:
                    await session.delete(row)
                else:
                    row.state = discovery_lifecycle.STATE_UNDECIDED
            await _drop_assignment(session, agent_id, check_name, item)
            counts["removed"] += 1
            continue

        params = dict(spec.get("parameters") or {})
        if item:
            params["item"] = item
        existing = await _find_assignment(session, agent_id, check_name, item)
        if existing is None:
            session.add(
                CheckAssignment(
                    tenant_id=DEFAULT_TENANT_ID, check_name=check_name, scope_type="host",
                    agent_id=agent_id, parameters=params, source="autodiscovered",
                    created_by=identity.name,
                )
            )
        elif params:
            existing.parameters = {**(existing.parameters or {}), **params}
        if row is not None:
            row.state = discovery_lifecycle.STATE_MONITORED
        counts["accepted"] += 1

    await session.commit()

    # If any container service was touched, the agent's monitored-container allow-list changed. Recompute
    # it from the full monitored set (not incrementally — the agent replaces its list wholesale) and push
    # it, so the agent starts/stops collecting that container. Done after commit so the set reflects the
    # decisions just persisted.
    result: dict[str, Any] = {"agent_id": str(agent_id), **counts, "assigned": counts["accepted"]}
    from bossman.services.discovery import CONTAINER_CHECK_NAME

    if any(spec.get("check_name") == CONTAINER_CHECK_NAME for _, spec in specs):
        sync = await _sync_monitored_containers(session, settings, client_factory, agent)
        result["container_sync"] = sync
    return result


async def _sync_monitored_containers(session, settings, client_factory, agent) -> dict[str, Any]:
    """Push the agent's monitored-container allow-list — every container currently in state=monitored.

    Replaced wholesale on the agent, so this sends the COMPLETE set: whatever is not in it the agent
    stops collecting. A push failure is reported, not raised — the operator's decision is already saved,
    and the agent can be re-synced later; failing the whole apply would lose that record."""
    from bossman.db.models import DiscoveredService
    from bossman.services.agent_client import AgentClientError
    from bossman.services.discovery import CONTAINER_CHECK_NAME
    from bossman.services import discovery_lifecycle

    rows = (
        await session.scalars(
            select(DiscoveredService.item).where(
                DiscoveredService.agent_id == agent.id,
                DiscoveredService.check_name == CONTAINER_CHECK_NAME,
                DiscoveredService.state == discovery_lifecycle.STATE_MONITORED,
            )
        )
    ).all()
    containers = sorted({r for r in rows if r})
    if not agent.address:
        return {"pushed": False, "reason": "agent has no direct address", "containers": containers}
    client = client_factory(agent, settings)
    try:
        await client.set_collect_config({"monitored_containers": containers})
    except AgentClientError as exc:
        return {"pushed": False, "reason": str(exc), "containers": containers}
    return {"pushed": True, "containers": containers}


async def _discovered_row(session: AsyncSession, agent_id: UUID, check_name: str, item: str):
    """The discovered_services row for one service identity, or None."""
    from bossman.db.models import DiscoveredService

    return await session.scalar(
        select(DiscoveredService).where(
            DiscoveredService.agent_id == agent_id,
            DiscoveredService.check_name == check_name,
            DiscoveredService.item == item,
        )
    )


async def _find_assignment(session: AsyncSession, agent_id: UUID, check_name: str, item: str):
    """The host-scoped assignment for one (check, item), or None.

    The item lives inside `parameters`, so this matches on the JSONB value — the same
    identity resolve_host_checks groups by.
    """
    rows = (
        await session.scalars(
            select(CheckAssignment).where(
                CheckAssignment.agent_id == agent_id,
                CheckAssignment.check_name == check_name,
                CheckAssignment.scope_type == "host",
            )
        )
    ).all()
    for a in rows:
        if str((a.parameters or {}).get("item") or "") == item:
            return a
    return None


async def _drop_assignment(session: AsyncSession, agent_id: UUID, check_name: str, item: str) -> None:
    if (a := await _find_assignment(session, agent_id, check_name, item)) is not None:
        await session.delete(a)


@router.get("/api/v1/agents/{agent_id}/discovered-services")
async def list_discovered_services(
    agent_id: UUID,
    state: str | None = None,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """What discovery knows about this host, by lifecycle state.

    This is the persisted discovery result (Checkmk's autochecks), NOT the monitoring
    state — a row here says "this service exists on the host", while services.state says
    OK/WARN/CRIT. Optional ?state= filters to one of
    undecided|monitored|vanished|ignored."""
    from bossman.db.models import DiscoveredService

    stmt = select(DiscoveredService).where(DiscoveredService.agent_id == agent_id)
    if state:
        stmt = stmt.where(DiscoveredService.state == state)
    rows = (await session.scalars(stmt.order_by(DiscoveredService.check_name, DiscoveredService.item))).all()
    counts: dict[str, int] = {}
    for r in rows:
        counts[r.state] = counts.get(r.state, 0) + 1
    return {
        "agent_id": str(agent_id),
        "counts": counts,
        "services": [
            {
                "check_name": r.check_name,
                "item": r.item,
                "state": r.state,
                "parameters": r.parameters or {},
                "service_labels": r.service_labels or {},
                "first_seen_at": r.first_seen_at,
                "last_seen_at": r.last_seen_at,
                "last_changed_at": r.last_changed_at,
            }
            for r in rows
        ],
    }


@router.get("/api/v1/agents/{agent_id}/host-labels")
async def list_host_labels(
    agent_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """This host's Checkmk-style labels, with where each came from.

    Distinct from Agent.tags (our host tags) and from metric-series labels."""
    from bossman.db.models import HostLabel

    rows = (
        await session.scalars(select(HostLabel).where(HostLabel.agent_id == agent_id).order_by(HostLabel.key))
    ).all()
    return {
        "agent_id": str(agent_id),
        "labels": [{"key": r.key, "value": r.value, "source": r.source} for r in rows],
    }


# ── Credential provisioning (Block G9-P3d) ─────────────────────────────────


@router.get("/api/v1/checks/{name}/provisioning")
async def check_provisioning(
    name: str, settings: Settings = Depends(get_settings), _identity=Depends(get_current_identity)
) -> dict[str, Any]:
    """Whether this check ships a provisioning recipe (create a monitoring
    account) and, if so, the admin params the wizard must collect."""
    from bossman.services import provisioning

    recipe = provisioning.load_recipe(settings.checks_dir, name)
    if recipe is None:
        return {"available": False}
    return {
        "available": True,
        "title": recipe.get("title", "Provision " + name),
        "description": recipe.get("description", ""),
        "admin_params": provisioning.admin_param_specs(recipe),
    }


@router.post("/api/v1/agents/{agent_id}/checks/{name}/provision")
async def provision_check(
    agent_id: UUID,
    name: str,
    body: dict[str, Any],
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity: Identity = Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Run the check's provisioning recipe on the host (create the monitoring
    account with the operator-supplied admin creds), then assign the check to
    the host with the generated monitoring credential. Admin creds are used
    only for the setup command and never stored. Needs manage rights on the
    host. body: {admin_params: {...}, extra_params?: {...}}."""
    from bossman.services import provisioning

    if not await user_can_manage_agent(session, identity, agent_id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
    recipe = provisioning.load_recipe(settings.checks_dir, name)
    if recipe is None:
        raise HTTPException(status_code=404, detail=f"check {name!r} has no provisioning recipe")
    agent = await _agent_with_address(session, agent_id)
    client = client_factory(agent, settings)
    result = await provisioning.provision(client, recipe, body.get("admin_params") or {})
    if not result["ok"]:
        raise HTTPException(status_code=422, detail=result["error"])

    params = {**(body.get("extra_params") or {}), **result["produced_params"]}
    a = CheckAssignment(
        tenant_id=DEFAULT_TENANT_ID, check_name=name, scope_type="host",
        agent_id=agent_id, parameters=params, source="autodiscovered", created_by=identity.name,
    )
    session.add(a)
    await session.commit()
    # never echo the admin creds; the produced monitoring cred is what was stored
    return {"assignment": _assignment_out(a), "provisioned": True}
