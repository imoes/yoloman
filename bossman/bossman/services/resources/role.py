"""RoleResource — a Role behind the Resource/Deployable contract, with BIND
semantics (docs/resource-protocol.md).

This resolves a contradiction the first version had: it executed a role's steps
directly against a host, which `POST /agents/{id}/runbook/run` deliberately
refuses ("that is a role, not a runbook — bind it in OU / Policy instead"). The
platform's own model, stated in services/nt_compile.py, is that a role maps 1:1
onto an **OrchestrationPlan** (`plan_type="role"`) and takes effect by being
**bound to a scope**; `compiler._build_desired_state()` then composes every bound
role into the host's desired state, which converges (push → generations → rollback).

So the OOP reading is exact:

    Role (OrchestrationPlan, plan_type="role")  = the CLASS
    OrchestrationPlanLink (scope + parameters)  = the INSTANCE (constructor args)
    compile → desired state → converge          = the RUNTIME

Hence the four verbs here are about the BINDING of one role to one host:
  schema()   → the role's parameters (its constructor)
  observe()  → is it bound to this host, from which scope, with which parameters
  plan()     → compiler.preview_plan_link(): blast radius + monitoring before/after,
               writing nothing (the platform's own "propose" primitive)
  apply()    → create the link, i.e. DECLARE the intent — then compile the host
  rollback() → re-bind with an earlier parameter set

Executing steps ad hoc is intentionally NOT offered: it would change the host
without recording intent, so the next convergence run would drift it back.

The approval gate is respected, not bypassed: a link starts `active` only under
global YOLO mode or when the caller opts out of approval — otherwise
`pending_approval`, which apply() reports honestly instead of pretending success.
"""
from __future__ import annotations

from typing import Any
from uuid import uuid4

from sqlalchemy import select

from bossman.db.models import OrchestrationPlan, OrchestrationPlanLink, OrchestrationPlanVersion
from bossman.services.compiler import (
    compile_host_desired_state,
    is_yolo_mode,
    preview_plan_link,
    resolve_orchestration_assignments,
)
from bossman.services.resources import base


class RoleResource:
    resource_type = "role"

    def __init__(self, session, agent, client_factory, settings, name: str,
                 requested_by: str = "resource-api"):
        self._session = session
        self._agent = agent
        self._settings = settings
        self._requested_by = requested_by
        self.name = name
        # the binding of THIS role to THIS host is what has generations
        self.resource_key = f"role:{agent.id}:{name}"
        self._plan: OrchestrationPlan | None = None
        self._schema: dict[str, Any] = {}

    # ---------------------------------------------------------------- lookup --

    async def _plan_row(self) -> OrchestrationPlan | None:
        """The role as a registered class: an OrchestrationPlan of type "role".
        (NestedText role docs are the AUTHORING surface; `POST /runbooks/role/
        compile` turns one into this plan — see services/nt_compile.py.)"""
        if self._plan is None:
            self._plan = (await self._session.scalars(
                select(OrchestrationPlan).where(
                    OrchestrationPlan.name == self.name,
                    OrchestrationPlan.plan_type == "role",
                    OrchestrationPlan.deleted_at.is_(None),
                )
            )).first()
        return self._plan

    async def _version_row(self) -> OrchestrationPlanVersion | None:
        plan = await self._plan_row()
        if plan is None:
            return None
        return (await self._session.scalars(
            select(OrchestrationPlanVersion).where(
                OrchestrationPlanVersion.plan_id == plan.id,
                OrchestrationPlanVersion.version == plan.current_version,
            )
        )).first()

    # ----------------------------------------------------------------- verbs --

    async def schema_async(self) -> dict[str, Any]:
        """The role's constructor: its declared parameter schema, or the shape of
        its defaults when no explicit schema was authored."""
        ver = await self._version_row()
        if ver is None:
            self._schema = {}
            return {}
        schema = dict(ver.parameter_schema or {})
        if not schema:
            defaults = ver.default_parameters or {}
            if _looks_like_param_specs(defaults):
                # A role compiled from NestedText carries its `parameters:` BLOCK
                # (i.e. specs, not values) in default_parameters — see
                # nt_compile.role_to_plan_input. Then that IS the schema.
                schema = {k: dict(v) for k, v in defaults.items()}
            else:
                # plain values → derive a form, typed by what is actually there
                # (same rule as the config tier: never widen a value's type)
                for key, val in defaults.items():
                    schema[key] = {"type": _lexical_type(val), "default": val}
        else:
            for key, spec in schema.items():
                if isinstance(spec, dict) and "default" not in spec:
                    dflt = (ver.default_parameters or {}).get(key)
                    if dflt is not None:
                        spec["default"] = dflt
        self._schema = schema
        return schema

    def schema(self) -> dict[str, Any]:
        """Sync half of the contract — serves what schema_async cached."""
        return self._schema

    async def observe(self) -> dict[str, Any] | None:
        """Is this role bound to this host — and how? Uses the platform's own
        inheritance resolution (global → OU ancestry → group → host-direct, most
        specific wins), so `source` names where the binding comes from."""
        plan = await self._plan_row()
        if plan is None:
            return None
        assignments = await resolve_orchestration_assignments(self._session, self._agent)
        mine = next((a for a in assignments if a.plan_id == plan.id), None)
        direct = (await self._session.scalars(
            select(OrchestrationPlanLink).where(
                OrchestrationPlanLink.plan_id == plan.id,
                OrchestrationPlanLink.agent_id == self._agent.id,
            )
        )).all()
        return {
            "name": self.name,
            "plan_version": plan.current_version,
            "enabled": plan.enabled,
            "bound": mine is not None,
            "source": mine.source if mine else None,        # e.g. "ou:/Germany/Prod"
            "parameters": mine.parameters if mine else {},   # link params over defaults
            "host_links": [
                {"id": str(link.id), "status": link.status, "parameters": link.parameters,
                 "priority": link.priority}
                for link in direct
            ],
        }

    async def plan(self, desired: dict[str, Any]) -> dict[str, Any]:
        """What binding this role to this host WOULD do — blast radius plus a
        monitoring before/after — computed by the platform's own propose
        primitive, which never writes."""
        plan_row = await self._plan_row()
        if plan_row is None:
            return {"resource_key": self.resource_key, "action": "noop",
                    "error": f"no such role: {self.name!r} (roles are OrchestrationPlans of type 'role')"}
        params = _params_of(desired)
        preview = await preview_plan_link(
            self._session, plan_row.tenant_id, plan_row.id, "host",
            agent_id=self._agent.id, parameters=params,
        )
        observed = await self.observe()
        already = bool(observed and observed.get("bound"))
        same = already and (observed or {}).get("parameters") == {
            **((await self._version_row()).default_parameters if await self._version_row() else {}), **params}
        return {
            "resource_key": self.resource_key,
            "action": "noop" if same else ("update" if already else "create"),
            "changed": {"parameters": [(observed or {}).get("parameters"), params]} if not same else {},
            "changed_count": 0 if same else 1,
            "preview": preview,          # blast radius + monitoring diff
            "observed": observed,
            "desired": {"parameters": params},
            "delegated_to": "orchestration.binding",
        }

    async def apply(self, desired: dict[str, Any], *, dry_run: bool = True,
                    note: str | None = None) -> dict[str, Any]:
        """DECLARE the intent: bind the role to this host with these parameters,
        then compile the host's desired state (which the convergence pipeline
        pushes). Respects the approval gate — a link only starts `active` under
        global YOLO mode or when approval is explicitly waived."""
        params = _params_of(desired)
        if dry_run:
            return {"dry_run": True, "plan": await self.plan(desired)}
        plan_row = await self._plan_row()
        if plan_row is None:
            return {"dry_run": False, "ok": False,
                    "error": f"no such role: {self.name!r}"}

        require_approval = bool(desired.get("require_approval", True))
        yolo = await is_yolo_mode(self._session)
        status = "active" if (yolo or not require_approval) else "pending_approval"

        # one host-direct link per role: update in place instead of stacking
        existing = (await self._session.scalars(
            select(OrchestrationPlanLink).where(
                OrchestrationPlanLink.plan_id == plan_row.id,
                OrchestrationPlanLink.agent_id == self._agent.id,
            )
        )).first()
        if existing is not None:
            existing.parameters = params
            existing.plan_version = plan_row.current_version
            existing.status = status
            link = existing
        else:
            link = OrchestrationPlanLink(
                id=uuid4(), tenant_id=plan_row.tenant_id, plan_id=plan_row.id,
                plan_version=plan_row.current_version, target_type="host",
                agent_id=self._agent.id, parameters=params, status=status,
            )
            self._session.add(link)
        await self._session.commit()

        compiled_generation = None
        if status == "active":
            compiled = await compile_host_desired_state(self._session, self._agent.id)
            await self._session.commit()
            compiled_generation = getattr(compiled, "generation", None) if compiled else None

        gen = await base.record_generation(
            self._session, self.resource_key, self.resource_type,
            {"name": self.name, "target_type": "host", "parameters": params}, note=note,
        )
        return {
            "dry_run": False, "ok": True, "bound": True, "link_id": str(link.id),
            "status": status,                    # active | pending_approval
            "awaiting_approval": status != "active",
            "compiled_generation": compiled_generation,
            "generation": gen,                   # this binding's own history
            "delegated_to": "orchestration.binding",
        }

    async def generations(self) -> list[dict[str, Any]]:
        """Applied BINDING parameter sets (rollback points). The per-step run audit
        is a different thing and lives in Runs."""
        return await base.list_generations(self._session, self.resource_key)

    async def rollback(self, generation: int) -> dict[str, Any]:
        spec = await base.get_generation_spec(self._session, self.resource_key, generation)
        if spec is None:
            return {"ok": False, "error": f"no generation {generation} for role {self.name}"}
        out = await self.apply({"parameters": spec.get("parameters") or {}},
                               dry_run=False, note=f"rollback to gen {generation}")
        out["caveat"] = ("re-bound with the earlier parameters; the host converges to that "
                         "desired state. Steps a role already ran that are not expressed as "
                         "desired state are not undone by this.")
        return out

    async def unbind(self) -> dict[str, Any]:
        """Remove the host-direct binding (the counterpart of apply) and recompile."""
        plan_row = await self._plan_row()
        if plan_row is None:
            return {"ok": False, "error": f"no such role: {self.name!r}"}
        links = (await self._session.scalars(
            select(OrchestrationPlanLink).where(
                OrchestrationPlanLink.plan_id == plan_row.id,
                OrchestrationPlanLink.agent_id == self._agent.id,
            )
        )).all()
        for link in links:
            await self._session.delete(link)
        await self._session.commit()
        await compile_host_desired_state(self._session, self._agent.id)
        await self._session.commit()
        return {"ok": True, "unbound": len(links)}


def _params_of(desired: dict[str, Any]) -> dict[str, Any]:
    """Accept {"parameters": {...}} or a bare parameter dict."""
    inner = desired.get("parameters")
    if isinstance(inner, dict):
        return inner
    return {k: v for k, v in desired.items() if k not in ("require_approval", "dry_run", "note")}


def _looks_like_param_specs(params: dict[str, Any]) -> bool:
    """True when every entry is a param SPEC ({type: …}) rather than a plain value —
    the shape nt_compile puts into default_parameters for a compiled role."""
    if not params:
        return False
    return all(isinstance(v, dict) and "type" in v for v in params.values())


def _lexical_type(value: Any) -> str:
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, list):
        return "list"
    if isinstance(value, dict):
        return "object"
    return "string"


__all__ = ["RoleResource"]
