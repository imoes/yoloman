"""Block G11 (NT format, step 7): the runbook REST surface — lint a NT
document, run a runbook against a host (dry-run/apply), and compile a role
into an OrchestrationPlan create-payload.

Runs the tested engine (services/nt_engine) over the agent client. `run` needs
manage rights on the host; a dry run (`dry_run: true`, the default) previews
every step in check_mode without touching the host — the same preview→confirm
posture as plan runs.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from bossman.api.auth import get_current_identity
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent, Runbook, RunbookRun, ScopeVars
from bossman.db.session import get_session
from bossman.services import nt_compile, nt_convert, nt_runbook
from bossman.services.auth import Identity, user_can_manage_agent
from bossman.services.runbook_exec import execute_runbook
from bossman.services.vault import Vault

router = APIRouter()

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


# ── Runbook CRUD (stored as canonical JSON, authored as NestedText) ────────


class SaveRunbookBody(BaseModel):
    nt: str | None = None
    yaml: str | None = None  # import an existing YAML playbook
    folder: str | None = None  # library folder path ("linux/base"); "" = root


def _to_doc(body: SaveRunbookBody) -> dict[str, Any]:
    if body.nt is not None:
        return nt_convert.nt_to_doc(body.nt)
    if body.yaml is not None:
        return nt_convert.yaml_to_doc(body.yaml)
    raise HTTPException(status_code=422, detail="provide `nt` or `yaml`")


@router.get("/api/v1/runbook-runs")
async def list_runbook_runs(
    agent_id: UUID | None = None,
    limit: int = 100,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Block F6 — runbook execution history, newest first (optionally one
    host). Sibling of GET /runs (plan runs) so the unified Runs page can list
    plan + runbook + deploy runs together."""
    stmt = select(RunbookRun).order_by(RunbookRun.created_at.desc()).limit(min(limit, 500))
    if agent_id is not None:
        stmt = stmt.where(RunbookRun.agent_id == agent_id)
    rows = (await session.scalars(stmt)).all()
    return {
        "runs": [
            {
                "id": str(r.id), "runbook_name": r.runbook_name, "agent_id": str(r.agent_id) if r.agent_id else None,
                "status": r.status, "dry_run": r.dry_run, "changed": r.changed,
                "requested_by": r.requested_by, "created_at": r.created_at.isoformat(),
            }
            for r in rows
        ]
    }


@router.get("/api/v1/runbooks")
async def list_runbooks(session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)) -> dict[str, Any]:
    rows = (await session.scalars(select(Runbook).where(Runbook.tenant_id == DEFAULT_TENANT_ID).order_by(Runbook.name))).all()
    return {"runbooks": [{"id": str(r.id), "name": r.name, "kind": r.kind, "folder": r.folder or "",
                          "updated_at": r.updated_at.isoformat() if r.updated_at else None} for r in rows]}


@router.get("/api/v1/runbooks/{runbook_id}")
async def get_runbook(runbook_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)) -> dict[str, Any]:
    r = await session.get(Runbook, runbook_id)
    if r is None:
        raise HTTPException(status_code=404, detail="no such runbook")
    return {"id": str(r.id), "name": r.name, "kind": r.kind, "folder": r.folder or "",
            "parameters": (r.doc or {}).get("parameters", {}), "doc": r.doc, "nt": nt_convert.doc_to_nt(r.doc)}


@router.post("/api/v1/runbooks")
async def create_runbook(body: SaveRunbookBody, session: AsyncSession = Depends(get_session), identity: Identity = Depends(get_current_identity)) -> dict[str, Any]:
    try:
        doc = _to_doc(body)
    except nt_runbook.NTRunbookError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    r = Runbook(tenant_id=DEFAULT_TENANT_ID, name=doc["name"], kind=doc.get("kind", "runbook"),
                folder=(body.folder or "").strip("/"), doc=doc, created_by=identity.name)
    session.add(r)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise HTTPException(status_code=409, detail=f"a runbook named {doc['name']!r} already exists") from exc
    return {"id": str(r.id), "name": r.name, "kind": r.kind}


@router.put("/api/v1/runbooks/{runbook_id}")
async def update_runbook(runbook_id: UUID, body: SaveRunbookBody, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)) -> dict[str, Any]:
    r = await session.get(Runbook, runbook_id)
    if r is None:
        raise HTTPException(status_code=404, detail="no such runbook")
    try:
        doc = _to_doc(body)
    except nt_runbook.NTRunbookError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    r.name = doc["name"]
    r.kind = doc.get("kind", "runbook")
    if body.folder is not None:
        r.folder = body.folder.strip("/")
    r.doc = doc
    await session.commit()
    return {"id": str(r.id), "name": r.name, "kind": r.kind, "folder": r.folder or ""}


@router.delete("/api/v1/runbooks/{runbook_id}", status_code=204)
async def delete_runbook(runbook_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)) -> None:
    r = await session.get(Runbook, runbook_id)
    if r is None:
        raise HTTPException(status_code=404, detail="no such runbook")
    await session.delete(r)
    await session.commit()


class NTBody(BaseModel):
    nt: str


@router.post("/api/v1/runbooks/lint")
async def lint_runbook(body: NTBody, _identity=Depends(get_current_identity)) -> dict[str, Any]:
    """Parse + shape-validate a NestedText runbook or role. Returns
    {ok, kind, name} or {ok: false, error}."""
    try:
        doc = nt_runbook.parse_document(body.nt)
    except nt_runbook.NTRunbookError as exc:
        return {"ok": False, "error": str(exc), "line": getattr(exc, "line", None)}
    # `doc` (the canonical dict) lets the editor rebuild its visual canvas from
    # the text — the round-trip that makes text→visual editing possible.
    return {"ok": True, "kind": doc.kind, "name": doc.name, "steps": len(doc.steps),
            "parameters": getattr(doc, "parameters", {}), "doc": doc.to_dict()}


class RunBody(BaseModel):
    nt: str
    variables: dict[str, Any] = {}
    dry_run: bool = True


@router.post("/api/v1/agents/{agent_id}/runbook/run")
async def run_runbook(
    agent_id: UUID,
    body: RunBody,
    session: AsyncSession = Depends(get_session),
    settings: Settings = Depends(get_settings),
    identity: Identity = Depends(get_current_identity),
    client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Run a NestedText runbook against a host. dry_run (default true) previews
    every step in check_mode. Needs manage rights on the host."""
    if not await user_can_manage_agent(session, identity, agent_id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="no such agent")
    if not agent.address:
        raise HTTPException(status_code=422, detail="agent has no address to reach")
    try:
        doc = nt_runbook.parse_document(body.nt)
    except nt_runbook.NTRunbookError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    if not isinstance(doc, nt_runbook.Runbook):
        raise HTTPException(status_code=422, detail="that is a role, not a runbook — bind it in OU / Policy instead")

    client = client_factory(agent, settings)
    run_row, rr = await execute_runbook(
        session, agent, doc, settings=settings, client=client,
        request_vars=body.variables, dry_run=body.dry_run, requested_by=identity.name,
    )
    return {"run_id": str(run_row.id), "agent_id": str(agent_id), "runbook": doc.name, **rr}


class ScopeVarsBody(BaseModel):
    scope_type: str  # ou | group | host
    ou_id: UUID | None = None
    host_group_id: UUID | None = None
    agent_id: UUID | None = None
    vars: dict[str, Any] = {}
    # Keys whose value is a secret: stored encrypted (vault:v1:…), masked on
    # read, decrypted only at run time. A secret key whose incoming value is
    # the mask means "unchanged" — keep the already-stored ciphertext.
    secret_keys: list[str] = []


def _scope_filter(stmt, scope_type: str, ou_id, host_group_id, agent_id):
    col = {"ou": (ScopeVars.ou_id, ou_id), "group": (ScopeVars.host_group_id, host_group_id),
           "host": (ScopeVars.agent_id, agent_id)}[scope_type]
    return stmt.where(ScopeVars.scope_type == scope_type, col[0] == col[1])


def _mask_vars(stored: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    """Return (display_vars, secret_keys): secret (encrypted) values replaced
    with the mask so plaintext never leaves the server; secret_keys lists which
    keys are secrets so the UI renders them as password fields."""
    display: dict[str, Any] = {}
    secret_keys: list[str] = []
    for k, v in (stored or {}).items():
        if Vault.is_encrypted(v):
            display[k] = Vault.mask()
            secret_keys.append(k)
        else:
            display[k] = v
    return display, secret_keys


@router.get("/api/v1/scope-vars")
async def get_scope_vars(
    scope_type: str, ou_id: UUID | None = None, host_group_id: UUID | None = None, agent_id: UUID | None = None,
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """The variables set directly on one scope target (not the resolved
    inheritance — a runbook run resolves that GPO-style). Secret values are
    masked; `secret_keys` tells the UI which to render as password fields."""
    if scope_type not in ("ou", "group", "host"):
        raise HTTPException(status_code=422, detail="scope_type must be ou|group|host")
    row = await session.scalar(_scope_filter(select(ScopeVars).where(ScopeVars.tenant_id == DEFAULT_TENANT_ID), scope_type, ou_id, host_group_id, agent_id))
    display, secret_keys = _mask_vars(row.vars if row else {})
    return {"vars": display, "secret_keys": secret_keys}


@router.put("/api/v1/scope-vars")
async def put_scope_vars(
    body: ScopeVarsBody, session: AsyncSession = Depends(get_session),
    identity: Identity = Depends(get_current_identity), settings: Settings = Depends(get_settings),
) -> dict[str, Any]:
    """Set (upsert) the variables on a host/group/OU. Host scope needs manage
    rights on the host; group/OU scope is admin-only (broad blast radius).
    Keys named in `secret_keys` are encrypted at rest; a secret whose incoming
    value is the mask keeps its existing ciphertext (edit-without-revealing)."""
    if body.scope_type not in ("ou", "group", "host"):
        raise HTTPException(status_code=422, detail="scope_type must be ou|group|host")
    scope_id = {"ou": body.ou_id, "group": body.host_group_id, "host": body.agent_id}[body.scope_type]
    if scope_id is None:
        raise HTTPException(status_code=422, detail=f"scope_type={body.scope_type} requires the matching id")
    if body.scope_type == "host":
        if not await user_can_manage_agent(session, identity, body.agent_id):
            raise HTTPException(status_code=403, detail="not authorized to manage this host")
    elif not (identity.kind == "user" and identity.role == "admin"):
        raise HTTPException(status_code=403, detail="group/OU vars are admin-only")

    row = await session.scalar(_scope_filter(select(ScopeVars).where(ScopeVars.tenant_id == DEFAULT_TENANT_ID), body.scope_type, body.ou_id, body.host_group_id, body.agent_id))
    existing = (row.vars if row else {}) or {}
    vault = Vault(settings.vault_key, settings.vault_key_path)
    secret = set(body.secret_keys)
    new_vars: dict[str, Any] = {}
    for k, v in body.vars.items():
        if k in secret:
            if v == Vault.mask():
                # Unchanged secret → keep existing ciphertext; a mask with no
                # prior ciphertext is an empty secret → drop it (don't encrypt
                # the mask placeholder itself).
                if Vault.is_encrypted(existing.get(k)):
                    new_vars[k] = existing[k]
            else:
                new_vars[k] = vault.encrypt(v if isinstance(v, str) else str(v))
        else:
            new_vars[k] = v

    if row is None:
        row = ScopeVars(tenant_id=DEFAULT_TENANT_ID, scope_type=body.scope_type,
                        ou_id=body.ou_id, host_group_id=body.host_group_id, agent_id=body.agent_id, vars=new_vars)
        session.add(row)
    else:
        row.vars = new_vars
    await session.commit()
    display, secret_keys = _mask_vars(row.vars)
    return {"id": str(row.id), "scope_type": row.scope_type, "vars": display, "secret_keys": secret_keys}


@router.get("/api/v1/runbook-runs")
async def list_runbook_runs(
    agent_id: UUID | None = None, limit: int = 50,
    session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """The runbook-run audit trail (newest first), optionally for one host."""
    stmt = select(RunbookRun).where(RunbookRun.tenant_id == DEFAULT_TENANT_ID)
    if agent_id is not None:
        stmt = stmt.where(RunbookRun.agent_id == agent_id)
    rows = (await session.scalars(stmt.order_by(RunbookRun.created_at.desc()).limit(limit))).all()
    return {"runs": [{"id": str(r.id), "runbook": r.runbook_name, "agent_id": str(r.agent_id) if r.agent_id else None,
                      "dry_run": r.dry_run, "status": r.status, "changed": r.changed,
                      "created_at": r.created_at.isoformat() if r.created_at else None} for r in rows]}


@router.get("/api/v1/runbook-runs/{run_id}")
async def get_runbook_run(run_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(get_current_identity)) -> dict[str, Any]:
    r = await session.get(RunbookRun, run_id)
    if r is None:
        raise HTTPException(status_code=404, detail="no such run")
    return {"id": str(r.id), "runbook": r.runbook_name, "agent_id": str(r.agent_id) if r.agent_id else None,
            "dry_run": r.dry_run, "status": r.status, "changed": r.changed, "result": r.result,
            "requested_by": r.requested_by, "created_at": r.created_at.isoformat() if r.created_at else None}


@router.post("/api/v1/runbooks/role/compile")
async def compile_role(body: NTBody, _identity=Depends(get_current_identity)) -> dict[str, Any]:
    """Compile a NestedText role into an OrchestrationPlan create-payload
    (name/display_name/plan_type/version with steps + generated_monitoring +
    notifications) — POST it to /api/v1/orchestration/plans to store it."""
    try:
        doc = nt_runbook.parse_document(body.nt)
    except nt_runbook.NTRunbookError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    if not isinstance(doc, nt_runbook.Role):
        raise HTTPException(status_code=422, detail="that is a runbook, not a role (needs a top-level `role:`)")
    return {"plan_input": nt_compile.role_to_plan_input(doc)}
