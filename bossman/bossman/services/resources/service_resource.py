"""ServiceResource — a systemd unit as a Resource (docs/resource-protocol.md).

Wraps the agent's `systemd` (apply) tool + a `systemctl is-active/is-enabled`
observe behind the four-verb contract with DB-backed generations + rollback. So a
service's running + enabled-at-boot state is managed the same observe→plan→apply→
rollback way as everything else, in the one generic inspector.
"""
from __future__ import annotations

from typing import Any

from bossman.services.resources import base

_FIELDS = ["enabled", "state"]
_SCHEMA: dict[str, Any] = {
    "name": {"type": "string", "required": True, "description": "unit name, e.g. nginx (.service implied)"},
    "enabled": {"type": "bool", "description": "start at boot (systemctl enable/disable)"},
    "state": {"type": "string", "enum": ["started", "stopped", "restarted", "reloaded"],
              "description": "running state; omit to only manage 'enabled'"},
}


class ServiceResource:
    resource_type = "service"

    def __init__(self, session, agent, client_factory, settings, name: str):
        self._session = session
        self._agent = agent
        self._cf = client_factory
        self._settings = settings
        self.name = name
        self.resource_key = f"service:{agent.id}:{name}"

    def schema(self) -> dict[str, Any]:
        return _SCHEMA

    async def observe(self) -> dict[str, Any] | None:
        """Current running + enabled state via systemctl (read-only)."""
        client = self._cf(self._agent, self._settings)
        unit = self.name if "." in self.name else f"{self.name}.service"
        script = f"systemctl is-active {unit} 2>/dev/null; echo '---'; systemctl is-enabled {unit} 2>/dev/null; true"
        try:
            res = await client.call_tool("command", {"argv": ["sh", "-lc", script]})
        except Exception:  # noqa: BLE001
            return None
        out = ((res.get("data") or {}).get("stdout") if isinstance(res, dict) else "") or ""
        parts = out.split("---")
        active = (parts[0] if parts else "").strip()
        enabled_raw = (parts[1] if len(parts) > 1 else "").strip()
        return {
            "name": self.name,
            "state": "started" if active == "active" else "stopped",
            "enabled": enabled_raw in ("enabled", "enabled-runtime", "static", "alias", "indirect"),
            "active_raw": active or "unknown", "enabled_raw": enabled_raw or "unknown",
        }

    async def plan(self, desired: dict[str, Any]) -> dict[str, Any]:
        observed = await self.observe()
        # Only diff the fields the caller actually set (like the systemd module,
        # which leaves an omitted field untouched); restarted/reloaded always change.
        fields = [f for f in _FIELDS if f in desired]
        obs_for_diff = observed
        if desired.get("state") in ("restarted", "reloaded") and observed is not None:
            obs_for_diff = {**observed, "state": "__action__"}
        d = base.diff_specs(obs_for_diff, {f: desired[f] for f in fields}, fields)
        d["resource_key"] = self.resource_key
        d["observed"] = observed
        d["desired"] = desired
        return d

    async def apply(self, desired: dict[str, Any], *, dry_run: bool = True,
                    note: str | None = None) -> dict[str, Any]:
        plan = await self.plan(desired)
        if dry_run:
            return {"dry_run": True, "plan": plan}
        args: dict[str, Any] = {"name": self.name, "dry_run": False}
        if "state" in desired:
            args["state"] = desired["state"]
        if "enabled" in desired:
            args["enabled"] = bool(desired["enabled"])
        client = self._cf(self._agent, self._settings)
        try:
            res = await client.call_tool("systemd", args)
        except Exception as exc:  # noqa: BLE001
            return {"dry_run": False, "ok": False, "error": str(exc)[:300], "plan": plan}
        gen = await base.record_generation(
            self._session, self.resource_key, self.resource_type,
            {"name": self.name, **{f: desired[f] for f in _FIELDS if f in desired}}, note=note)
        return {"dry_run": False, "ok": True, "generation": gen, "plan": plan, "result": res.get("data") if isinstance(res, dict) else res}

    async def generations(self) -> list[dict[str, Any]]:
        return await base.list_generations(self._session, self.resource_key)

    async def rollback(self, generation: int) -> dict[str, Any]:
        spec = await base.get_generation_spec(self._session, self.resource_key, generation)
        if spec is None:
            return await base.no_such_generation(self._session, self.resource_key, generation, self.name)
        return await self.apply(spec, dry_run=False, note=f"rollback to gen {generation}")
