"""RoleResource — a runbook Role behind the Resource/Deployable contract
(docs/resource-protocol.md). This is the OOP reading of a Role made literal:

    Role            = the class          (steps = its body)
    parameters      = the constructor    → schema() → a typed form
    running it      = instantiating it   → apply()

Two histories, deliberately kept apart because they are different facts:
  * `runbook_runs` (engine-owned) = the EXECUTION audit — what happened, per step.
  * `ResourceGeneration` (this adapter) = the applied PARAMETER SETS = the
    rollback points. The engine never recorded the params, so rollback would
    otherwise be a guess; storing the desired spec here makes it truthful.

Honesty about rollback: re-applying an earlier parameter set is a
FORWARD-CONVERGE (same as the other tiers). It only truly reverts if the role's
steps are idempotent — a role that appends or runs one-way commands cannot be
undone by re-running it with older values. The API says so in the result.
"""
from __future__ import annotations

from typing import Any

from sqlalchemy import select

from bossman.db.models import Runbook, RunbookRun
from bossman.services import nt_runbook
from bossman.services.resources import base
from bossman.services.runbook_exec import execute_runbook


class RoleResource:
    resource_type = "role"

    def __init__(self, session, agent, client_factory, settings, name: str, requested_by: str = "resource-api"):
        self._session = session
        self._agent = agent
        self._cf = client_factory
        self._settings = settings
        self._requested_by = requested_by
        self.name = name
        self.resource_key = f"role:{agent.id}:{name}"
        self._doc: dict[str, Any] | None = None

    async def _role_doc(self) -> dict[str, Any] | None:
        if self._doc is None:
            row = (await self._session.scalars(
                select(Runbook).where(Runbook.name == self.name, Runbook.kind == "role")
            )).first()
            self._doc = row.doc if row is not None else {}
        return self._doc or None

    async def schema_async(self) -> dict[str, Any]:
        """The role's `parameters` block — its constructor, rendered as a form.
        Async because the doc lives in the DB; `schema()` serves the cached copy
        once anything has loaded it (Resource contract compatibility)."""
        doc = await self._role_doc()
        return (doc or {}).get("parameters") or {}

    def schema(self) -> dict[str, Any]:
        return (self._doc or {}).get("parameters") or {}

    async def observe(self) -> dict[str, Any] | None:
        """A role has no continuously observable value; the truthful observation is
        its last execution against this host (status/changed/when) + its parameter
        surface."""
        doc = await self._role_doc()
        if doc is None:
            return None
        last = (await self._session.scalars(
            select(RunbookRun).where(
                RunbookRun.runbook_name == self.name, RunbookRun.agent_id == self._agent.id
            ).order_by(RunbookRun.created_at.desc()).limit(1)
        )).first()
        return {
            "name": self.name,
            "steps": len((doc.get("steps") or [])),
            "parameters": list((doc.get("parameters") or {}).keys()),
            "last_run": None if last is None else {
                "status": last.status, "changed": last.changed, "dry_run": last.dry_run,
                "at": last.created_at.isoformat() if last.created_at else None,
                "requested_by": last.requested_by,
            },
        }

    async def _run(self, params: dict[str, Any], dry_run: bool) -> dict[str, Any]:
        doc = await self._role_doc()
        if not doc:
            raise ValueError(f"no such role: {self.name!r}")
        # A Role's body is executed as a runbook against this one host: roles and
        # runbooks share the step grammar, only the binding differs.
        runbook = nt_runbook.parse_document(_doc_to_nt_runbook(doc))
        _row, result = await execute_runbook(
            self._session, self._agent, runbook, settings=self._settings,
            client=self._cf(self._agent, self._settings), request_vars=params,
            dry_run=dry_run, requested_by=self._requested_by,
        )
        return result

    async def plan(self, desired: dict[str, Any]) -> dict[str, Any]:
        """Check-mode run: the steps that WOULD change (the role's dry-run)."""
        params = desired.get("parameters") if isinstance(desired.get("parameters"), dict) else desired
        result = await self._run(params or {}, dry_run=True)
        steps = result.get("steps") or []
        changing = [s for s in steps if s.get("changed") or s.get("status") == "changed"]
        return {
            "resource_key": self.resource_key,
            "action": "update" if changing else "noop",
            "changed": {s.get("name", f"step{i}"): [None, s.get("status")] for i, s in enumerate(changing)},
            "changed_count": len(changing),
            "desired": {"parameters": params or {}},
            "steps_total": len(steps),
            "delegated_to": "runbook.engine",
        }

    async def apply(self, desired: dict[str, Any], *, dry_run: bool = True,
                    note: str | None = None) -> dict[str, Any]:
        params = desired.get("parameters") if isinstance(desired.get("parameters"), dict) else desired
        params = params or {}
        if dry_run:
            return {"dry_run": True, "plan": await self.plan({"parameters": params})}
        result = await self._run(params, dry_run=False)
        ok = bool(result.get("ok", True)) and not result.get("aborted")
        out: dict[str, Any] = {
            "dry_run": False, "ok": ok, "changed": bool(result.get("changed")),
            "run": {"steps": len(result.get("steps") or []), "aborted": bool(result.get("aborted"))},
            "delegated_to": "runbook.engine",
        }
        if not ok:
            out["error"] = "role run failed — see the run audit (Runs)"
            return out
        # record the applied PARAMETER SET as the rollback point (the engine's run
        # audit does not keep params, so without this a rollback would be a guess).
        out["generation"] = await base.record_generation(
            self._session, self.resource_key, self.resource_type,
            {"name": self.name, "parameters": params}, note=note,
        )
        return out

    async def generations(self) -> list[dict[str, Any]]:
        """Applied parameter sets (rollback points). The per-step execution audit
        lives in Runs (runbook_runs), not here."""
        return await base.list_generations(self._session, self.resource_key)

    async def rollback(self, generation: int) -> dict[str, Any]:
        spec = await base.get_generation_spec(self._session, self.resource_key, generation)
        if spec is None:
            return {"ok": False, "error": f"no generation {generation} for role {self.name}"}
        out = await self.apply({"parameters": spec.get("parameters") or {}},
                               dry_run=False, note=f"rollback to gen {generation}")
        out["caveat"] = ("forward-converge: the role was re-run with the earlier parameters. "
                         "This only truly reverts if its steps are idempotent.")
        return out


def _doc_to_nt_runbook(doc: dict[str, Any]) -> str:
    """Render a stored role doc as NestedText the parser accepts as a RUNBOOK
    (kind: runbook), so the engine executes its steps against one host. Roles and
    runbooks share the step grammar; only the binding differs."""
    from bossman.services import nt_convert
    body = dict(doc)
    body["kind"] = "runbook"
    return nt_convert.doc_to_nt(body)
