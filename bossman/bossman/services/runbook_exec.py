"""Execute a NestedText runbook against one host — the shared core behind
both the REST endpoint (`POST /agents/{id}/runbook/run`) and the `yolo-man
runbook run` CLI (Block G11).

It gathers the Ansible-style magic variables (the agent's own facts, incl.
hardware/DMI), layers the variable scopes in GPO precedence, drives the NT
engine, and records a RunbookRun audit row — so a CLI run and a UI run are
indistinguishable in the audit trail.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import Agent, RunbookRun
from bossman.services import nt_engine, nt_runbook
from bossman.services.plan_loader import load_host_vars
from bossman.services.scope_vars import resolve_scope_vars
from bossman.services.vault import Vault

DEFAULT_TENANT_ID = UUID("00000000-0000-0000-0000-000000000001")


async def gather_magic_vars(client: Any, agent: Agent) -> dict[str, Any]:
    """The agent's own facts (hostname, distribution, hardware/DMI) as
    ${yoloman_*}/${inventory_hostname} (the agent also emits ${ansible_*}
    aliases for imported content). Best-effort: a failed `setup` never blocks
    the run — the runbook proceeds with what it has."""
    magic: dict[str, Any] = {"inventory_hostname": agent.name}
    try:
        facts_resp = await client.call_tool("setup", {})
        if isinstance(facts_resp, dict):
            facts = facts_resp.get("data") if isinstance(facts_resp.get("data"), dict) else facts_resp
            if isinstance(facts, dict):
                magic.update(facts)
    except Exception:  # noqa: BLE001 — facts are best-effort, never block the run
        pass
    # The full HW/SW inventory document (Block H1) as the `inventory` magic var,
    # reached in runbooks via dotted paths — ${inventory.product.serial},
    # ${inventory.cpu.model}, ${inventory.memory.total_mb}, ${inventory.disks}.
    try:
        hosts = await client.hosts_overview()
        if isinstance(hosts, list):
            self_host = next((h for h in hosts if isinstance(h, dict) and not h.get("parent")), None)
            inv = (self_host or {}).get("inventory") if self_host else None
            if isinstance(inv, dict):
                magic["inventory"] = inv
    except Exception:  # noqa: BLE001 — best-effort, never block the run
        pass
    return magic


async def resolve_run_variables(
    session: AsyncSession, agent: Agent, settings: Settings, magic: dict[str, Any], request_vars: dict[str, Any],
) -> dict[str, Any]:
    """Layer the variable scopes weakest→strongest: magic facts < filesystem
    host_vars < GPO-resolved scope vars (group < OU root→leaf < host) <
    explicit request variables."""
    try:
        host_vars = load_host_vars(settings.plans_dir, agent.name) or {}
    except Exception:  # noqa: BLE001
        host_vars = {}
    scope_v = await resolve_scope_vars(session, agent)
    merged = {**magic, **host_vars, **scope_v, **(request_vars or {})}
    # Decrypt any vault-encrypted secret values only now, at the last moment
    # before they're handed to the agent over the already-secure channel — they
    # were never plaintext at rest and are still masked in the UI/audit.
    vault = Vault(settings.vault_key, settings.vault_key_path)
    return {k: (vault.decrypt(v) if Vault.is_encrypted(v) else v) for k, v in merged.items()}


async def _expand_role_calls(
    session: AsyncSession, steps: list[nt_runbook.Step], seen: tuple[str, ...] = (), depth: int = 0,
) -> tuple[list[nt_runbook.Step], dict[str, Any]]:
    """Inline every `runbook:` step (a role call) with the referenced runbook's
    steps — the Ansible import_role-as-task equivalent. Returns the flattened
    step list plus the variables the calls contribute (the callee's parameter
    defaults, then its explicit `vars`), which the caller layers weakly so an
    unset field still gets the role's default. Recursive with cycle + depth
    guards; the agent never sees a "runbook" module. v1: contributed vars share
    the flat run scope (fine for the wizard's single-role calls)."""
    from bossman.db.models import Runbook
    from bossman.services import nt_convert
    from sqlalchemy import select

    if depth > 8:
        raise nt_runbook.NTRunbookError("runbook includes nested too deep (>8) — cycle?")
    out: list[nt_runbook.Step] = []
    collected: dict[str, Any] = {}
    for step in steps:
        if step.module != "runbook":
            out.append(step)
            continue
        ref = step.args.get("name")
        if ref in seen:
            raise nt_runbook.NTRunbookError(f"runbook include cycle: {' -> '.join((*seen, ref))}")
        row = await session.scalar(
            select(Runbook).where(Runbook.tenant_id == DEFAULT_TENANT_ID, Runbook.name == ref)
        )
        if row is None:
            raise nt_runbook.NTRunbookError(f"runbook step: no such runbook {ref!r}")
        sub = nt_runbook.parse_document(nt_convert.doc_to_nt(row.doc))
        if not isinstance(sub, nt_runbook.Runbook):
            raise nt_runbook.NTRunbookError(f"runbook step: {ref!r} is a role, not a runbook")
        # Callee parameter defaults (weakest), then the call's explicit vars.
        for pname, spec in (sub.parameters or {}).items():
            if isinstance(spec, dict) and spec.get("default") is not None:
                collected[pname] = spec["default"]
        collected.update(step.args.get("vars") or {})
        sub_steps, sub_vars = await _expand_role_calls(session, sub.steps, (*seen, ref), depth + 1)
        collected.update(sub_vars)
        out.extend(sub_steps)
    return out, collected


async def execute_runbook(
    session: AsyncSession,
    agent: Agent,
    doc: nt_runbook.Runbook,
    *,
    settings: Settings,
    client: Any,
    request_vars: dict[str, Any] | None = None,
    dry_run: bool = True,
    requested_by: str,
    commit: bool = True,
) -> tuple[RunbookRun, dict[str, Any]]:
    """Run `doc` against `agent`, persisting a RunbookRun. Returns the audit
    row plus the engine result dict (with `facts_gathered`)."""
    # Inline any `runbook:` role calls first, so the engine sees one flat step
    # list (it has no DB access). The calls contribute their callees' defaults +
    # vars as a weak variable layer.
    include_vars: dict[str, Any] = {}
    if any(s.module == "runbook" for s in doc.steps):
        flat_steps, include_vars = await _expand_role_calls(session, doc.steps)
        doc = nt_runbook.Runbook(
            name=doc.name, targets=doc.targets, parameters=getattr(doc, "parameters", {}) or {}, steps=flat_steps,
        )

    magic = await gather_magic_vars(client, agent)
    variables = await resolve_run_variables(session, agent, settings, magic, request_vars or {})
    if include_vars:
        variables = {**include_vars, **variables}
    # A runbook's typed parameter defaults are the WEAKEST layer — they fill in
    # anything the caller/facts/scope-vars didn't supply (so the wizard's install
    # runbooks work even when a field is left at its default and omitted).
    param_defaults = {
        name: spec["default"]
        for name, spec in (getattr(doc, "parameters", {}) or {}).items()
        if isinstance(spec, dict) and spec.get("default") is not None
    }
    if param_defaults:
        variables = {**param_defaults, **variables}

    # Config templates a `config_template` step can render (name -> Jinja2 body).
    from bossman.api.config_templates import load_template_bodies

    templates = load_template_bodies(settings)
    result = await nt_engine.run_runbook(doc, client, variables, check_mode=dry_run, templates=templates)
    rr = result.to_dict()
    rr["facts_gathered"] = len(magic) - 1

    run_row = RunbookRun(
        tenant_id=DEFAULT_TENANT_ID, runbook_name=doc.name, agent_id=agent.id,
        dry_run=dry_run, status=("ok" if result.ok else ("aborted" if result.aborted else "failed")),
        changed=result.changed, result=rr, requested_by=requested_by,
    )
    session.add(run_row)
    if commit:
        await session.commit()
    return run_row, rr
