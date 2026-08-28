"""Event handlers CRUD + the availability check for locally-placed ones.

An event handler is the reusable ACTION an event rule performs: a runbook, or a script that
Bossman either manages and deploys or finds already present on the host. The trigger stays in
services/remediation.py — see docs/event-handling.md.

Two things this module is deliberate about:

* **Validation mirrors the database constraints and says WHY.** The forbidden combinations are
  already impossible in the schema (a runbook cannot be local; a local handler cannot declare
  parameters; a managed script needs its source). Answering with a bare 409 from Postgres would
  be a refusal without a reason, so each is checked here first and answered with the sentence
  that explains it.
* **`/availability` exists because a `local` handler is otherwise an untested claim.** Its body
  is not in Bossman; whether the file is actually on a host is only discovered when the event
  fires, which is exactly too late. A host where it is missing is a NAMED state, never an
  omitted row.
"""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import Identity, get_current_identity
from bossman.api.etag import check_if_match, compute_version
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import DEFAULT_TENANT_ID, Agent, EventHandler, RemediationPolicy, Runbook
from bossman.db.session import get_session
from bossman.services import event_handlers as eh

router = APIRouter()

_BODIES = ("runbook", "script")
_LOCATIONS = ("managed", "local")
#: Interpreters offered. A free-text field would let someone name a binary the host does not
#: have, and the failure would surface only when an event fires.
_INTERPRETERS = ("bash", "sh", "python3", "perl", "ruby", "node")


class ParameterSpec(BaseModel):
    name: str
    type: str = "string"
    default: str | None = None
    description: str = ""
    required: bool = False


class EventHandlerIn(BaseModel):
    name: str
    description: str = ""
    body: str = "script"
    location: str = "managed"
    runbook_name: str | None = None
    interpreter: str | None = None
    source: str | None = None
    local_name: str | None = None
    parameters: list[ParameterSpec] = []
    timeout_s: int = 300
    enabled: bool = True


class EventHandlerOut(BaseModel):
    id: UUID
    name: str
    description: str
    body: str
    location: str
    runbook_name: str | None
    interpreter: str | None
    source: str | None
    local_name: str | None
    parameters: list[ParameterSpec]
    timeout_s: int
    enabled: bool
    created_at: datetime
    #: Where a script would live on the host — shown so the operator can look for it, and so a
    #: `local` handler's file name is unambiguous.
    script_path: str | None = None
    #: How many event rules use this handler. Deleting one that is in use is refused
    #: (ON DELETE RESTRICT), so the count is the reason, available before the attempt.
    used_by_rules: int = 0
    #: Send back as If-Match on PUT — a concurrent edit becomes a 412 instead of a silent
    #: overwrite (api/etag.py).
    version: str = ""

    @classmethod
    def of(cls, h: EventHandler, *, used_by_rules: int = 0) -> "EventHandlerOut":
        out = cls(
            id=h.id, name=h.name, description=h.description, body=h.body, location=h.location,
            runbook_name=h.runbook_name, interpreter=h.interpreter, source=h.source,
            local_name=h.local_name,
            parameters=[ParameterSpec(**p) for p in (h.parameters or []) if isinstance(p, dict)],
            timeout_s=h.timeout_s, enabled=h.enabled, created_at=h.created_at,
            script_path=(None if h.body == "runbook" else eh.script_path(h)),
            used_by_rules=used_by_rules,
        )
        out.version = compute_version(out)
        return out


async def _rule_count(session: AsyncSession, handler_id: UUID) -> int:
    rows = (
        await session.scalars(
            select(RemediationPolicy.id).where(RemediationPolicy.event_handler_id == handler_id)
        )
    ).all()
    return len(rows)


async def _validate(body: EventHandlerIn, session: AsyncSession) -> None:
    """Every refusal names its reason. These mirror the CHECK constraints in the schema — the
    database is the guarantee, this is the explanation."""
    if not body.name.strip():
        raise HTTPException(422, "name is required")
    if body.body not in _BODIES:
        raise HTTPException(422, f"body must be one of {'|'.join(_BODIES)}")
    if body.location not in _LOCATIONS:
        raise HTTPException(422, f"location must be one of {'|'.join(_LOCATIONS)}")

    if body.body == "runbook":
        if body.location != "managed":
            raise HTTPException(
                422,
                "a runbook handler cannot be local: a runbook is a document in Bossman's "
                "database, so there is nothing on the host to point at",
            )
        if not (body.runbook_name or "").strip():
            raise HTTPException(422, "runbook_name is required when body is 'runbook'")
        rb = await session.scalar(select(Runbook.id).where(Runbook.name == body.runbook_name))
        if rb is None:
            # Named now rather than at the moment an event fires, which is when it would
            # otherwise surface.
            raise HTTPException(422, f"no runbook named {body.runbook_name!r}")
        return

    # script
    if body.location == "managed":
        if not (body.interpreter or "").strip():
            raise HTTPException(422, "interpreter is required for a script handler")
        if body.interpreter not in _INTERPRETERS:
            raise HTTPException(422, f"interpreter must be one of {'|'.join(_INTERPRETERS)}")
        if not (body.source or "").strip():
            raise HTTPException(
                422, "source is required for a Bossman-managed script — that text IS the handler"
            )
        if body.local_name:
            raise HTTPException(422, "local_name belongs to a local handler, not a managed one")
        return

    # script + local
    if not (body.local_name or "").strip():
        raise HTTPException(422, "local_name is required for a local handler")
    if body.source:
        raise HTTPException(
            422,
            "a local handler has no source in Bossman: its body is the file already on the host "
            "(under " + eh.HANDLER_DIR + ")",
        )
    if body.parameters:
        raise HTTPException(
            422,
            "a local handler cannot declare parameters: Bossman does not know the script's "
            "contents, so it cannot say which parameters it accepts, of what type, or whether "
            "they are required — a form for values it cannot describe would promise an effect "
            "nobody can check. The event context (host, service, state, value) is passed "
            "regardless, because that is the fact that caused the run, not a parameter.",
        )


def _apply(handler: EventHandler, body: EventHandlerIn) -> None:
    handler.name = body.name.strip()
    handler.description = body.description
    handler.body = body.body
    handler.location = body.location
    handler.runbook_name = body.runbook_name if body.body == "runbook" else None
    handler.interpreter = body.interpreter if body.body == "script" and body.location == "managed" else None
    handler.source = body.source if body.body == "script" and body.location == "managed" else None
    handler.local_name = body.local_name if body.location == "local" else None
    handler.parameters = [p.model_dump() for p in body.parameters]
    handler.timeout_s = body.timeout_s
    handler.enabled = body.enabled
    handler.updated_at = datetime.now(timezone.utc)


class HandlerMeta(BaseModel):
    """The legal values, served rather than duplicated.

    The UI needs the same lists this module validates against; hard-coding them there would be a
    second source of truth that drifts the moment one side gains an interpreter (the
    /resource-kinds endpoint exists for the same reason). `handler_dir` travels too, so the
    screen can name the exact path an operator has to place a local script in.
    """

    bodies: list[str]
    locations: list[str]
    interpreters: list[str]
    handler_dir: str
    #: Why a local handler declares no parameters — served so the form can SHOW the reason
    #: instead of only greying a field out.
    local_no_parameters_reason: str


@router.get("/api/v1/event-handlers/meta", response_model=HandlerMeta)
async def event_handler_meta(_i: Identity = Depends(get_current_identity)) -> HandlerMeta:
    return HandlerMeta(
        bodies=list(_BODIES), locations=list(_LOCATIONS), interpreters=list(_INTERPRETERS),
        handler_dir=eh.HANDLER_DIR,
        local_no_parameters_reason=(
            "Bossman does not have this script's contents — it lives on the host — so it cannot "
            "say which parameters it accepts, of what type, or whether they are required. A form "
            "for values it cannot describe would promise an effect nobody can check. The event "
            "context (host, service, state, value) is passed regardless: that is the fact that "
            "caused the run, not a parameter."
        ),
    )


@router.get("/api/v1/event-handlers", response_model=list[EventHandlerOut])
async def list_event_handlers(
    session: AsyncSession = Depends(get_session), _i: Identity = Depends(get_current_identity)
) -> list[EventHandlerOut]:
    rows = (await session.scalars(select(EventHandler).order_by(EventHandler.name))).all()
    return [EventHandlerOut.of(h, used_by_rules=await _rule_count(session, h.id)) for h in rows]


@router.post("/api/v1/event-handlers", response_model=EventHandlerOut, status_code=201)
async def create_event_handler(
    body: EventHandlerIn,
    session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity),
) -> EventHandlerOut:
    await _validate(body, session)
    handler = EventHandler(id=uuid4(), tenant_id=DEFAULT_TENANT_ID, created_by=identity.name)
    _apply(handler, body)
    session.add(handler)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(409, f"an event handler named {body.name!r} already exists") from exc
    return EventHandlerOut.of(handler)


async def _get_or_404(session: AsyncSession, handler_id: UUID) -> EventHandler:
    handler = await session.get(EventHandler, handler_id)
    if handler is None:
        raise HTTPException(404, f"no such event handler {handler_id}")
    return handler


@router.get("/api/v1/event-handlers/{handler_id}", response_model=EventHandlerOut)
async def get_event_handler(
    handler_id: UUID,
    session: AsyncSession = Depends(get_session),
    _i: Identity = Depends(get_current_identity),
) -> EventHandlerOut:
    handler = await _get_or_404(session, handler_id)
    return EventHandlerOut.of(handler, used_by_rules=await _rule_count(session, handler_id))


@router.put("/api/v1/event-handlers/{handler_id}", response_model=EventHandlerOut)
async def update_event_handler(
    handler_id: UUID,
    body: EventHandlerIn,
    request: Request,
    session: AsyncSession = Depends(get_session),
    _i: Identity = Depends(get_current_identity),
) -> EventHandlerOut:
    handler = await _get_or_404(session, handler_id)
    check_if_match(request, EventHandlerOut.of(handler).version)
    await _validate(body, session)
    _apply(handler, body)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(409, f"an event handler named {body.name!r} already exists") from exc
    return EventHandlerOut.of(handler, used_by_rules=await _rule_count(session, handler_id))


@router.delete("/api/v1/event-handlers/{handler_id}", status_code=204)
async def delete_event_handler(
    handler_id: UUID,
    session: AsyncSession = Depends(get_session),
    _i: Identity = Depends(get_current_identity),
) -> None:
    handler = await _get_or_404(session, handler_id)
    used = await _rule_count(session, handler_id)
    if used:
        # The FK is ON DELETE RESTRICT, so the database would refuse anyway — this says how many
        # rules stand in the way instead of surfacing a constraint name.
        raise HTTPException(
            409,
            f"{used} event rule(s) still use this handler; point them elsewhere first "
            "(deleting it would leave a rule that fires and does nothing)",
        )
    await session.delete(handler)
    await session.commit()


class HostAvailability(BaseModel):
    agent_id: UUID
    host: str
    #: present | missing | unreachable | unknown — four named outcomes, because "not there",
    #: "could not ask" and "that is not a host" are different facts and only the first means the
    #: operator has to go and install a file.
    state: str
    detail: str = ""


class AvailabilityOut(BaseModel):
    handler_id: UUID
    name: str
    location: str
    script_path: str | None
    hosts: list[HostAvailability]
    present_on: int
    checked: int


@router.get("/api/v1/event-handlers/{handler_id}/availability", response_model=AvailabilityOut)
async def event_handler_availability(
    handler_id: UUID,
    agent_ids: list[UUID] = Query(default=[], description="Hosts to check; omit for every host with an address"),
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _i: Identity = Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> AvailabilityOut:
    """Is this handler's file actually on the hosts?

    Only meaningful for `location=local`: a managed script is deployed by the run itself, and a
    runbook lives in this database. For a local one the body is outside Bossman, so without this
    check "the handler will run" is a claim nobody has tested until the event fires.

    A host that cannot be reached is reported as `unreachable`, not as `missing`: treating the
    two alike would tell the operator to install a file that may well already be there.
    """
    handler = await _get_or_404(session, handler_id)
    if handler.location != "local":
        raise HTTPException(
            422,
            "availability applies to local handlers only: a managed script is deployed by the "
            "run itself, and a runbook is a row in this database",
        )

    if agent_ids:
        agents = (await session.scalars(select(Agent).where(Agent.id.in_(agent_ids)))).all()
    else:
        agents = (await session.scalars(select(Agent).where(Agent.address.isnot(None)))).all()

    file_name = eh.script_path(handler).rsplit("/", 1)[-1]
    hosts: list[HostAvailability] = []

    # An id the caller asked about that is not a host gets its own row. Dropping it would answer
    # a question about 3 hosts with 2 rows and no mention of the third — the same silent
    # disappearance this audit keeps finding elsewhere.
    known = {a.id for a in agents}
    for missing_id in [i for i in agent_ids if i not in known]:
        hosts.append(HostAvailability(
            agent_id=missing_id, host=str(missing_id), state="unknown",
            detail="no such host — it may have been deleted since the caller listed it",
        ))
    for agent in sorted(agents, key=lambda a: a.name or ""):
        if not agent.address:
            hosts.append(HostAvailability(
                agent_id=agent.id, host=agent.name, state="unreachable",
                detail="host has no address, so its handler directory cannot be read",
            ))
            continue
        found = await eh.local_availability(client_factory(agent, settings), [file_name])
        present = bool(found.get(file_name))
        hosts.append(HostAvailability(
            agent_id=agent.id, host=agent.name,
            state="present" if present else "missing",
            detail="" if present else f"{eh.HANDLER_DIR}/{file_name} not found on this host",
        ))

    return AvailabilityOut(
        handler_id=handler.id, name=handler.name, location=handler.location,
        script_path=eh.script_path(handler), hosts=hosts,
        present_on=sum(1 for h in hosts if h.state == "present"),
        checked=len(hosts),
    )
