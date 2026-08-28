"""Event rules API — bind a trigger (a check entering a hard problem state, within a scope) to
an ACTION: a runbook, or an event handler which may be a script. Plus the run history and the
manual apply/dismiss/trigger. Engine: services/remediation, action: services/event_handlers.

**Naming.** The operator-facing name is "event rule", because "remediation" describes only one of
several purposes (notifying, cleaning up, escalating are not repairs) — see docs/event-handling.md.
The canonical paths are therefore `/api/v1/event-rules` and `/api/v1/event-runs`, with
`/api/v1/agents/{id}/trigger-event-rules` for the manual trigger.

The old `/remediation-*` paths still answer, marked deprecated and hidden from the schema. A grep
of this repository found exactly ONE caller (the UI client, now moved), and no MCP tool, chat tool,
agent or CLI used them — but "no caller here" is not "no caller anywhere", and an operator's script
should not break because a name improved. They are aliases, not a second way to do something: the
same function serves both, so the two can never diverge in behaviour.

The DATABASE tables (`remediation_policies`, `remediation_runs`) and the ORM classes keep their
names. Renaming a table is a migration and an irreversible step for stored data; leaving class and
table aligned means there are two names in total (code/DB vs operator/API) with the translation
stated here and in the UI model, rather than three.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import DEFAULT_TENANT_ID, Agent, RemediationPolicy, RemediationRun, Runbook
from bossman.db.session import get_session

router = APIRouter()


class RemediationPolicyIn(BaseModel):
    name: str
    match_service_name: str = ""  # "" = any check
    scope_type: str = "global"    # global|ou|group|host
    ou_id: UUID | None = None
    host_group_id: UUID | None = None
    agent_id: UUID | None = None
    conditions: dict = {}
    #: The action. EXACTLY ONE of these two: `runbook_name` is the original inline form,
    #: `event_handler_id` points at a reusable EventHandler (which may be a script). Both would
    #: be two answers to "what runs?", neither would be a rule that fires and does nothing —
    #: the schema enforces it (ck_remediation_one_action) and _validate_action says why.
    runbook_name: str = ""
    event_handler_id: UUID | None = None
    params: dict = {}
    max_per_hour: int = 3
    mode: str = "auto"            # auto | propose (legacy)
    enabled: bool = True
    # closed-loop verify (Phase 1) + autonomy (Phase 2)
    verify: bool = True
    verify_after_s: int = 60
    autonomy: str = "propose"     # propose | auto_verify
    allow_prod: bool = False
    max_blast_radius: int = 1
    rollback_runbook: str | None = None


class RemediationPolicyOut(BaseModel):
    id: UUID
    name: str
    match_service_name: str
    scope_type: str
    ou_id: UUID | None
    host_group_id: UUID | None
    agent_id: UUID | None
    conditions: dict
    runbook_name: str
    event_handler_id: UUID | None
    params: dict
    max_per_hour: int
    mode: str
    enabled: bool
    verify: bool
    verify_after_s: int
    autonomy: str
    allow_prod: bool
    max_blast_radius: int
    rollback_runbook: str | None

    @classmethod
    def of(cls, p: RemediationPolicy) -> "RemediationPolicyOut":
        return cls(
            id=p.id, name=p.name, match_service_name=p.match_service_name, scope_type=p.scope_type,
            ou_id=p.ou_id, host_group_id=p.host_group_id, agent_id=p.agent_id, conditions=p.conditions or {},
            runbook_name=p.runbook_name, event_handler_id=p.event_handler_id, params=p.params or {},
            max_per_hour=p.max_per_hour,
            mode=p.mode, enabled=p.enabled, verify=p.verify, verify_after_s=p.verify_after_s,
            autonomy=p.autonomy, allow_prod=p.allow_prod, max_blast_radius=p.max_blast_radius,
            rollback_runbook=p.rollback_runbook,
        )


@router.get("/api/v1/event-rules", response_model=list[RemediationPolicyOut])
@router.get("/api/v1/remediation-policies", response_model=list[RemediationPolicyOut], deprecated=True, include_in_schema=False)
async def list_remediation_policies(session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    """Every event rule: what fires, where it applies, and what it is allowed to do.

        Newest first. A rule ties a **trigger** (a check entering a hard problem state, plus optional
        conditions and a scope) to an **action** (a runbook or an event handler) and to the
        **guardrails** that decide whether that action may run unattended.

        Read `autonomy`, not `mode` — see the create endpoint for why that matters.
        """
    rows = (await session.scalars(select(RemediationPolicy).order_by(RemediationPolicy.created_at.desc()))).all()
    return [RemediationPolicyOut.of(p) for p in rows]


async def _validate_action(body: RemediationPolicyIn, session: AsyncSession) -> None:
    """Exactly one action, and it must exist.

    The schema already forbids both-or-neither; this says WHY, and it resolves the reference now
    rather than at the moment an event fires — which is the worst time to learn that a runbook or
    handler was renamed away.
    """
    has_runbook = bool((body.runbook_name or "").strip())
    has_handler = body.event_handler_id is not None
    if has_runbook and has_handler:
        raise HTTPException(
            422,
            "a rule has ONE action: either a runbook name or an event handler, not both — two "
            "would be two answers to the question of what runs",
        )
    if not has_runbook and not has_handler:
        raise HTTPException(
            422,
            "a rule needs an action: pick a runbook or an event handler, otherwise it would fire "
            "and do nothing",
        )
    if has_handler:
        from bossman.db.models import EventHandler

        handler = await session.get(EventHandler, body.event_handler_id)
        if handler is None:
            raise HTTPException(422, f"no such event handler {body.event_handler_id}")
        if not handler.enabled:
            raise HTTPException(
                422, f"event handler {handler.name!r} is disabled, so the rule could not act"
            )
        # Required parameters with no value and no default would fail at run time with the host
        # already involved; named here instead.
        from bossman.services.event_handlers import missing_required

        missing = missing_required(handler, body.params or {})
        if missing:
            raise HTTPException(
                422,
                f"event handler {handler.name!r} requires parameter(s) with no value: "
                f"{', '.join(missing)}",
            )
    else:
        rb = await session.scalar(select(Runbook.id).where(Runbook.name == body.runbook_name))
        if rb is None:
            raise HTTPException(422, f"no runbook named {body.runbook_name!r}")


@router.post("/api/v1/event-rules", response_model=RemediationPolicyOut)
@router.post("/api/v1/remediation-policies", response_model=RemediationPolicyOut, deprecated=True, include_in_schema=False)
async def create_remediation_policy(
    body: RemediationPolicyIn, session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
):
    """Create an event rule — and the one thing to get right here is autonomy.

        **Exactly one action**: either `runbook_name` or `event_handler_id`, never both and never
        neither (422). The reference is resolved now rather than when an event fires, because the
        moment a fix is needed is the worst moment to learn its runbook was renamed away.

        **`autonomy` is the real gate; `mode` is inert.** `mode: auto|propose` is still validated and
        stored — and nothing in the engine reads it (docs/closed-loop-remediation.md records that
        `autonomy` replaced it semantically). A rule with `mode: "auto"` and `autonomy: "propose"`
        will only ever propose. Both fields stay in the payload for callers that still send them;
        only `autonomy` decides.

        A fix runs unattended only if **every** one of these holds, and each No is reported as the
        reason the proposal is waiting for a human:

        1. the server-wide autonomy kill-switch is on (it is off by default),
        2. the rule is `enabled`,
        3. `autonomy` is `auto_verify`,
        4. the host is not production, or `allow_prod` is set,
        5. fewer than `max_per_hour` runs for this rule on this host in the last hour,
        6. fewer than `max_blast_radius` hosts touched by this rule in this cycle.

        `verify` + `verify_after_s` re-check the service afterwards; `rollback_runbook` is what runs
        when that verification fails. Every attempt — applied, proposed or refused — is recorded.
        """
    if body.scope_type not in ("global", "ou", "group", "host"):
        raise HTTPException(422, "scope_type must be global|ou|group|host")
    if body.mode not in ("auto", "propose"):
        raise HTTPException(422, "mode must be auto|propose")
    if body.autonomy not in ("propose", "auto_verify"):
        raise HTTPException(422, "autonomy must be propose|auto_verify")
    await _validate_action(body, session)
    p = RemediationPolicy(
        tenant_id=DEFAULT_TENANT_ID, name=body.name, match_service_name=body.match_service_name,
        scope_type=body.scope_type, ou_id=body.ou_id, host_group_id=body.host_group_id, agent_id=body.agent_id,
        conditions=body.conditions or {},
        # The constraint wants the unused half empty, not null: "" is the absence of an inline
        # runbook, and NULL is the absence of a handler.
        runbook_name=(body.runbook_name or "") if body.event_handler_id is None else "",
        event_handler_id=body.event_handler_id, params=body.params or {},
        max_per_hour=body.max_per_hour, mode=body.mode, enabled=body.enabled,
        verify=body.verify, verify_after_s=body.verify_after_s, autonomy=body.autonomy,
        allow_prod=body.allow_prod, max_blast_radius=body.max_blast_radius, rollback_runbook=body.rollback_runbook,
        created_by=identity.name,
    )
    session.add(p)
    await session.commit()
    await session.refresh(p)
    return RemediationPolicyOut.of(p)


@router.put("/api/v1/event-rules/{policy_id}", response_model=RemediationPolicyOut)
@router.put("/api/v1/remediation-policies/{policy_id}", response_model=RemediationPolicyOut, deprecated=True, include_in_schema=False)
async def update_remediation_policy(
    policy_id: UUID, body: RemediationPolicyIn, session: AsyncSession = Depends(get_session),
    _i: Identity = Depends(get_current_identity),
):
    """Edit a rule in place.

    This did not exist, so "editing" a rule meant deleting and recreating it — and because
    remediation_runs.policy_id is ON DELETE SET NULL, that silently cut every past run loose from
    the rule that caused it. The audit trail would still list the runs and no longer be able to
    say why they happened.
    """
    p = await session.get(RemediationPolicy, policy_id)
    if p is None:
        raise HTTPException(404, f"no such remediation policy {policy_id}")
    if body.scope_type not in ("global", "ou", "group", "host"):
        raise HTTPException(422, "scope_type must be global|ou|group|host")
    if body.mode not in ("auto", "propose"):
        raise HTTPException(422, "mode must be auto|propose")
    if body.autonomy not in ("propose", "auto_verify"):
        raise HTTPException(422, "autonomy must be propose|auto_verify")
    await _validate_action(body, session)

    p.name = body.name
    p.match_service_name = body.match_service_name
    p.scope_type = body.scope_type
    p.ou_id = body.ou_id
    p.host_group_id = body.host_group_id
    p.agent_id = body.agent_id
    p.conditions = body.conditions or {}
    p.runbook_name = (body.runbook_name or "") if body.event_handler_id is None else ""
    p.event_handler_id = body.event_handler_id
    p.params = body.params or {}
    p.max_per_hour = body.max_per_hour
    p.mode = body.mode
    p.enabled = body.enabled
    p.verify = body.verify
    p.verify_after_s = body.verify_after_s
    p.autonomy = body.autonomy
    p.allow_prod = body.allow_prod
    p.max_blast_radius = body.max_blast_radius
    p.rollback_runbook = body.rollback_runbook
    await session.commit()
    await session.refresh(p)
    return RemediationPolicyOut.of(p)


@router.delete("/api/v1/event-rules/{policy_id}", status_code=204)
@router.delete("/api/v1/remediation-policies/{policy_id}", status_code=204, deprecated=True, include_in_schema=False)
async def delete_remediation_policy(policy_id: UUID, session: AsyncSession = Depends(get_session),
                                    _i: Identity = Depends(get_current_identity)):
    """Delete an event rule.

        **204 whether or not it existed.** A delete states a desired end condition, and that
        condition holds either way; a 404 would make a retry look like a failure.

        Its run history survives, but the link does not: `remediation_runs.policy_id` is
        `ON DELETE SET NULL`, so past runs keep *what* ran (`action`, as `kind:name`) and lose *which
        rule* caused it. To stop a rule firing without losing that, set `enabled: false` instead.
        """
    p = await session.get(RemediationPolicy, policy_id)
    if p is not None:
        await session.delete(p)
        await session.commit()


class RemediationRunOut(BaseModel):
    id: UUID
    policy_id: UUID | None
    agent_id: UUID | None
    service_name: str
    runbook_name: str
    #: WHAT ran, as "kind:name" — the answer the history keeps even after its rule is deleted.
    action: str
    status: str
    detail: str | None
    at: datetime
    # closed-loop lifecycle
    phase: str
    applied_at: datetime | None
    verified_at: datetime | None
    verify_state: str | None
    verify_ok: bool | None
    outcome: str | None


@router.get("/api/v1/event-runs", response_model=list[RemediationRunOut])
@router.get("/api/v1/remediation-runs", response_model=list[RemediationRunOut], deprecated=True, include_in_schema=False)
async def list_remediation_runs(status: str | None = Query(None), limit: int = Query(100, ge=1, le=500),
                                session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)):
    """Remediation history + the pending-proposal queue (?status=pending)."""
    stmt = select(RemediationRun)
    if status:
        stmt = stmt.where(RemediationRun.status == status)
    rows = (await session.scalars(stmt.order_by(RemediationRun.at.desc()).limit(limit))).all()
    return [RemediationRunOut(
        id=r.id, policy_id=r.policy_id, agent_id=r.agent_id, service_name=r.service_name,
        runbook_name=r.runbook_name, action=r.action or (f"runbook:{r.runbook_name}" if r.runbook_name else ""),
        status=r.status, detail=r.detail, at=r.at,
        phase=r.phase, applied_at=r.applied_at, verified_at=r.verified_at,
        verify_state=r.verify_state, verify_ok=r.verify_ok, outcome=r.outcome,
    ) for r in rows]


@router.post("/api/v1/event-runs/{run_id}/apply")
@router.post("/api/v1/remediation-runs/{run_id}/apply", deprecated=True, include_in_schema=False)
async def apply_remediation_run(
    run_id: UUID, session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _i: Identity = Depends(get_current_identity), client_factory=Depends(get_client_factory),
) -> dict:
    """Apply a PENDING remediation proposal now — the manual "Apply" action.
    Self-healing never runs automatically; this is the only execution path
    (besides the direct /remediate trigger)."""
    run = await session.get(RemediationRun, run_id)
    if run is None:
        raise HTTPException(404, "no such remediation run")
    if run.status != "pending":
        raise HTTPException(409, f"run is '{run.status}', not pending")
    from bossman.services.remediation import apply_run

    result = await apply_run(session, settings, run, client_factory)
    await session.commit()
    return result


@router.post("/api/v1/event-runs/{run_id}/dismiss", status_code=204)
@router.post("/api/v1/remediation-runs/{run_id}/dismiss", status_code=204, deprecated=True, include_in_schema=False)
async def dismiss_remediation_run(run_id: UUID, session: AsyncSession = Depends(get_session),
                                  _i: Identity = Depends(get_current_identity)) -> None:
    """Dismiss a pending proposal without running it."""
    run = await session.get(RemediationRun, run_id)
    if run is not None and run.status == "pending":
        run.status = "dismissed"
        await session.commit()


@router.post("/api/v1/agents/{agent_id}/trigger-event-rules")
@router.post("/api/v1/agents/{agent_id}/remediate", deprecated=True, include_in_schema=False)
async def trigger_remediation(
    agent_id: UUID, service: str = Query(...),
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _i: Identity = Depends(get_current_identity), client_factory=Depends(get_client_factory),
) -> dict:
    """Manually run the remediation policies matching (host, check) now — bypasses
    the rate limit (an operator/AI-initiated heal)."""
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(404, "no such host")
    from bossman.services.remediation import run_remediations_for_service

    results = await run_remediations_for_service(session, settings, agent, service, client_factory, force=True)
    await session.commit()
    return {"host": agent.name, "service": service, "results": results}
