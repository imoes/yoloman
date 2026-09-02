"""PackageResource — an OS package as a Resource (docs/resource-protocol.md).

Wraps the agent's `package` (apply) + `package_facts` (observe) tools behind the
four-verb contract with DB-backed generations + rollback. So a package is managed
the same observe→plan→apply→rollback way as config/containers/helm, in the one
generic inspector — present/absent/latest, versioned and undoable.
"""
from __future__ import annotations

from typing import Any

from bossman.services.resources import base

_FIELDS = ["state"]
_SCHEMA: dict[str, Any] = {
    "name": {"type": "string", "required": True, "description": "package name, e.g. nginx"},
    "state": {"type": "string", "enum": ["present", "absent", "latest"], "default": "present",
              "description": "present = installed, absent = removed, latest = upgraded to newest"},
}


class PackageResource:
    resource_type = "package"

    def __init__(self, session, agent, client_factory, settings, name: str):
        self._session = session
        self._agent = agent
        self._cf = client_factory
        self._settings = settings
        self.name = name
        self.resource_key = f"package:{agent.id}:{name}"

    def schema(self) -> dict[str, Any]:
        return _SCHEMA

    async def observe(self) -> dict[str, Any] | None:
        """Is the package installed (and at what version)? via package_facts."""
        client = self._cf(self._agent, self._settings)
        res = await client.call_tool("package_facts", {})
        data = res.get("data") if isinstance(res, dict) else None
        pkgs = data if isinstance(data, list) else (data or {}).get("packages") if isinstance(data, dict) else None
        for p in pkgs or []:
            if isinstance(p, dict) and p.get("name") == self.name:
                return {"name": self.name, "state": "present", "version": p.get("version")}
        return {"name": self.name, "state": "absent"}

    async def plan(self, desired: dict[str, Any]) -> dict[str, Any]:
        observed = await self.observe()
        # "latest" always plans as a potential change (can't tell newest-available offline).
        obs_for_diff = observed
        if desired.get("state") == "latest" and observed and observed.get("state") == "present":
            obs_for_diff = {**observed, "state": "present-maybe-outdated"}
        d = base.diff_specs(obs_for_diff, {"state": desired.get("state", "present")}, _FIELDS)
        d["resource_key"] = self.resource_key
        d["observed"] = observed
        d["desired"] = desired
        return d

    async def apply(self, desired: dict[str, Any], *, dry_run: bool = True,
                    note: str | None = None) -> dict[str, Any]:
        plan = await self.plan(desired)
        if dry_run:
            return {"dry_run": True, "plan": plan}
        client = self._cf(self._agent, self._settings)
        try:
            res = await client.call_tool("package", {"name": [self.name],
                                                     "state": desired.get("state", "present"), "dry_run": False})
        except Exception as exc:  # noqa: BLE001
            return {"dry_run": False, "ok": False, "error": str(exc)[:300], "plan": plan}
        gen = await base.record_generation(
            self._session, self.resource_key, self.resource_type,
            {"name": self.name, "state": desired.get("state", "present")}, note=note)
        return {"dry_run": False, "ok": True, "generation": gen, "plan": plan, "result": res.get("data") if isinstance(res, dict) else res}

    async def generations(self) -> list[dict[str, Any]]:
        return await base.list_generations(self._session, self.resource_key)

    async def rollback(self, generation: int) -> dict[str, Any]:
        spec = await base.get_generation_spec(self._session, self.resource_key, generation)
        if spec is None:
            return await base.no_such_generation(self._session, self.resource_key, generation, self.name)
        return await self.apply(spec, dry_run=False, note=f"rollback to gen {generation}")
