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

from bossman.api.auth import get_current_identity, require_admin
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent, Runbook, RunbookRun, ScopeVars
from bossman.db.session import get_session
from bossman.services import ansible_playbook, nt_compile, nt_runbook
from bossman.services.auth import Identity, user_can_manage_agent
from bossman.services.runbook_exec import execute_runbook
from bossman.services.vault import Vault

router = APIRouter()

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


# ── Runbook CRUD (stored as canonical JSON, authored in Ansible task syntax) ─


class SaveRunbookBody(BaseModel):
    """Ansible task syntax is the only authoring format (`playbook`). `doc` accepts the canonical JSON
    directly, for callers that already hold a parsed document (the visual editor, the AI author)."""
    playbook: str | None = None
    doc: dict[str, Any] | None = None
    folder: str | None = None  # library folder path ("linux/base"); "" = root


def _to_doc(body: SaveRunbookBody) -> dict[str, Any]:
    if body.playbook is not None:
        try:
            return ansible_playbook.parse_playbook(body.playbook).to_dict()
        except ansible_playbook.PlaybookError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
    if body.doc is not None:
        # Validate it through the same shape rules the text path uses — a doc coming in over the wire is no
        # more trustworthy than a document someone typed.
        return nt_runbook.parse_data(body.doc, source="doc").to_dict()
    raise HTTPException(status_code=422, detail="provide `playbook` or `doc`")


def _effect(r: RunbookRun) -> str:
    """The playbook-job outcome an operator reads at a glance: failed > changed >
    unchanged. `status` is the engine verdict (ok|failed|aborted); `changed`
    the idempotency flag. Rendered as a colour badge in the Event Browser."""
    if r.status in ("failed", "aborted"):
        return "failed"
    return "changed" if r.changed else "unchanged"


@router.get("/api/v1/runbook-runs")
async def list_runbook_runs(
    agent_id: UUID | None = None,
    status: str | None = None,
    effect: str | None = None,
    q: str | None = None,
    limit: int = 100,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Block F6 — runbook execution history, newest first (optionally one
    host). Sibling of GET /runs (plan runs) so the unified Runs page can list
    plan + runbook + deploy runs together. The Event Browser adds status/effect
    (failed|changed|unchanged) and `q` (requested_by/runbook substring) filters.
    Each row carries `host` (resolved agent hostname) and `effect` so the UI
    renders the changed/failed/unchanged badge without a second lookup."""
    stmt = select(RunbookRun).order_by(RunbookRun.created_at.desc()).limit(min(limit, 500))
    if agent_id is not None:
        stmt = stmt.where(RunbookRun.agent_id == agent_id)
    if status:
        stmt = stmt.where(RunbookRun.status == status)
    if q:
        like = f"%{q}%"
        stmt = stmt.where(RunbookRun.runbook_name.ilike(like) | RunbookRun.requested_by.ilike(like))
    rows = (await session.scalars(stmt)).all()
    # Resolve hostnames in one round-trip rather than N+1 per row.
    ids = {r.agent_id for r in rows if r.agent_id}
    hosts: dict[UUID, str] = {}
    if ids:
        for a in (await session.scalars(select(Agent).where(Agent.id.in_(ids)))).all():
            hosts[a.id] = a.name
    runs = [
        {
            "id": str(r.id), "runbook_name": r.runbook_name, "agent_id": str(r.agent_id) if r.agent_id else None,
            "host": hosts.get(r.agent_id) if r.agent_id else None,
            "status": r.status, "effect": _effect(r), "dry_run": r.dry_run, "changed": r.changed,
            "requested_by": r.requested_by, "created_at": r.created_at.isoformat(),
        }
        for r in rows
    ]
    if effect:
        runs = [x for x in runs if x["effect"] == effect]
    return {"runs": runs}


@router.get("/api/v1/runbook-runs/{run_id}")
async def get_runbook_run(
    run_id: UUID,
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """Full detail of one play — the engine's per-step RunResult (`result`) as
    stored JSON, so the Event Browser can render it like a playbook job (each
    step ok/changed/skipped/failed) plus who ran it and when."""
    r = await session.get(RunbookRun, run_id)
    if r is None:
        raise HTTPException(status_code=404, detail="no such run")
    host = None
    if r.agent_id:
        a = await session.get(Agent, r.agent_id)
        host = a.name if a else None
    return {
        "id": str(r.id), "runbook_name": r.runbook_name, "agent_id": str(r.agent_id) if r.agent_id else None,
        "host": host, "status": r.status, "effect": _effect(r), "dry_run": r.dry_run, "changed": r.changed,
        "requested_by": r.requested_by, "created_at": r.created_at.isoformat(), "result": r.result or {},
    }


@router.delete("/api/v1/runbook-runs")
async def purge_runbook_runs(
    older_than_days: int | None = None,
    session: AsyncSession = Depends(get_session),
    _identity: Identity = Depends(require_admin),
) -> dict[str, int]:
    """Clear play history (admin only). Without `older_than_days` deletes the
    whole runbook_runs history; with it, only rows older than that many days.
    Complements the automatic retention sweep in services/housekeeping."""
    from datetime import datetime, timedelta, timezone
    from sqlalchemy import delete as sa_delete

    stmt = sa_delete(RunbookRun)
    if older_than_days is not None and older_than_days > 0:
        cutoff = datetime.now(timezone.utc) - timedelta(days=older_than_days)
        stmt = stmt.where(RunbookRun.created_at < cutoff)
    result = await session.execute(stmt)
    await session.commit()
    return {"deleted": result.rowcount or 0}


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
            "parameters": (r.doc or {}).get("parameters", {}), "doc": r.doc,
            "playbook": ansible_playbook.doc_to_playbook(r.doc or {})}


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


class LintBody(BaseModel):
    playbook: str | None = None  # Ansible-task YAML — the only authoring format


@router.post("/api/v1/runbooks/lint")
async def lint_runbook(body: LintBody, _identity=Depends(get_current_identity)) -> dict[str, Any]:
    """Parse + shape-validate a runbook written in Ansible task syntax. Returns {ok, kind, name, doc,
    playbook} (the canonical `doc` rebuilds the visual canvas; `playbook` is the doc rendered back to Ansible
    YAML for the text view) or {ok: false, error}."""
    try:
        if body.playbook is not None:
            doc = ansible_playbook.parse_playbook(body.playbook)
        else:
            return {"ok": False, "error": "provide `playbook`"}
    except (nt_runbook.NTRunbookError, ansible_playbook.PlaybookError) as exc:
        return {"ok": False, "error": str(exc), "line": getattr(exc, "line", None)}
    d = doc.to_dict()
    return {"ok": True, "kind": doc.kind, "name": doc.name, "steps": len(doc.steps),
            "parameters": getattr(doc, "parameters", {}), "doc": d,
            "playbook": ansible_playbook.doc_to_playbook(d)}


_NL_SYSTEM = """You turn an operator's plain-language request into an Ansible playbook that Bossman runs on ONE Linux host.

Output ONLY a YAML task list — no prose, no explanations, no ``` fences. Each task has:
- name: a short human description
- exactly one module from: shell, command, package, service, copy, file, lineinfile, template, set_fact, debug
- the module's arguments as a mapping

Rules:
- Prefer typed modules (package/service/file/lineinfile/copy) over shell; use shell/command ONLY for actions no module covers.
- Do NOT invent module names. Keep it minimal and idempotent.
- No `hosts:`, `become:`, or play wrapper — just the flat list of tasks.
- If the request needs a value you don't know, use a sensible default and note it in the task name.

Example output:
- name: Ensure nginx is installed
  package: { name: nginx, state: present }
- name: Enable and start nginx
  service: { name: nginx, state: started, enabled: true }
"""


class FromNlBody(BaseModel):
    instruction: str
    backend: str | None = None        # optional per-request chat-backend override


async def _complete_text(backend, system: str, user: str) -> str:
    """One-shot completion by accumulating the backend's stream deltas (every
    backend implements stream; complete_with_tools is optional)."""
    from bossman.services.chat_backend import ChatBackendError

    chunks: list[str] = []
    try:
        async for ev in backend.stream([{"role": "user", "content": user}], system=system):
            if ev.get("type") == "delta" and ev.get("text"):
                chunks.append(ev["text"])
            elif ev.get("type") == "error":
                raise ChatBackendError(ev.get("text") or "backend error")
    except ChatBackendError:
        raise
    return "".join(chunks)


def _strip_fences(text: str) -> str:
    """Drop a leading/trailing ``` / ```yaml fence the model may add anyway."""
    t = (text or "").strip()
    if t.startswith("```"):
        lines = t.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        t = "\n".join(lines).strip()
    return t


@router.post("/api/v1/runbooks/from-nl")
async def runbook_from_nl(
    body: FromNlBody,
    settings: Settings = Depends(get_settings),
    _identity=Depends(get_current_identity),
) -> dict[str, Any]:
    """NL → typed runbook (Agentic-OS reasoning): turn a plain-language instruction
    into an Ansible playbook via the chat LLM, then parse + shape-validate it (the
    same lint the editor uses). Returns {ok, doc, playbook} so the runbook editor
    can load it for the operator to review, dry-run and apply — the model authors,
    the human confirms. Does NOT execute anything."""
    from bossman.services.chat_backend import ChatBackendError, chat_backend_for

    instruction = (body.instruction or "").strip()
    if not instruction:
        raise HTTPException(status_code=422, detail="instruction is required")
    try:
        backend = chat_backend_for(settings, body.backend)
        raw = await _complete_text(backend, _NL_SYSTEM, instruction)
    except ChatBackendError as exc:
        raise HTTPException(status_code=502, detail=f"chat backend: {exc}") from exc

    playbook_text = _strip_fences(raw)
    if not playbook_text:
        return {"ok": False, "error": "the model returned nothing", "raw": raw[:4096]}
    try:
        doc = ansible_playbook.parse_playbook(playbook_text)
    except (nt_runbook.NTRunbookError, ansible_playbook.PlaybookError) as exc:
        # Hand the raw YAML back so the operator can fix it in the editor.
        return {"ok": False, "error": f"generated playbook did not parse: {exc}",
                "playbook": playbook_text, "raw": raw[:4096]}
    d = doc.to_dict()
    return {"ok": True, "kind": doc.kind, "name": doc.name, "steps": len(doc.steps),
            "doc": d, "playbook": ansible_playbook.doc_to_playbook(d), "instruction": instruction}


class RunBody(BaseModel):
    playbook: str | None = None       # Ansible task YAML
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
    """Run a runbook (Ansible task YAML) against a host. dry_run (default true) previews every step in
    check_mode. Needs manage rights on the host."""
    if not await user_can_manage_agent(session, identity, agent_id):
        raise HTTPException(status_code=403, detail="not authorized to manage this host")
    agent = await session.get(Agent, agent_id)
    if agent is None:
        raise HTTPException(status_code=404, detail="no such agent")
    if not agent.address:
        raise HTTPException(status_code=422, detail="agent has no address to reach")
    try:
        if body.playbook is None:
            raise HTTPException(status_code=422, detail="provide `playbook`")
        doc = ansible_playbook.parse_playbook(body.playbook)
    except (nt_runbook.NTRunbookError, ansible_playbook.PlaybookError) as exc:
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
async def compile_role(body: LintBody, _identity=Depends(get_current_identity)) -> dict[str, Any]:
    """Compile a role into an OrchestrationPlan create-payload (name/display_name/plan_type/version with
    steps + generated_monitoring + notifications) — POST it to /api/v1/orchestration/plans to store it.

    A role is Ansible task syntax under a `role:` key, plus `monitoring.checks` / `notifications.routes`."""
    if body.playbook is None:
        raise HTTPException(status_code=422, detail="provide `playbook`")
    try:
        doc = ansible_playbook.parse_playbook(body.playbook)
    except (nt_runbook.NTRunbookError, ansible_playbook.PlaybookError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    if not isinstance(doc, nt_runbook.Role):
        raise HTTPException(status_code=422, detail="that is a runbook, not a role (needs a top-level `role:`)")
    return {"plan_input": nt_compile.role_to_plan_input(doc)}
