"""ConfigResource — the native-config tier behind the Resource/Deployable
contract (docs/resource-protocol.md), as a DELEGATING ADAPTER.

Unlike docker/helm (whose generations live in Bossman's ResourceGeneration
store), a host's config generations already live in the AGENT's state store (Go
internal/state: plan/apply/generations/rollback). So ConfigResource does NOT use
the Bossman generation store — it delegates every verb to the agent state API,
so there is ONE config history (the agent's), not two competing ones.

Consequence, stated honestly: config generations are HOST-document-scoped (a
generation = the host's whole desired config doc), not per-file like docker/helm.
observe/plan/apply target this one file; generations/rollback are the host's.
"""
from __future__ import annotations

from typing import Any

from bossman.services import config_schema


class ConfigResource:
    resource_type = "config"

    def __init__(self, session, agent, client_factory, settings, path: str):
        self._agent = agent
        self._client = client_factory(agent, settings)
        self._settings = settings
        self.path = path
        self.resource_key = f"config:{agent.id}:{path}"
        self._index: dict[str, list[str]] = {}   # flat key → exact segments (set by observe)
        self._schema: dict[str, Any] = {}

    async def schema_async(self) -> dict[str, Any]:
        """ONE TYPED FIELD PER DIRECTIVE actually present in the file, enriched by
        the mined catalog (enum/description). Async because it needs the observed
        values (the ground truth of what the file contains) plus the catalog.

        Empty when the file has no codec (observed carries only raw/sha256) — then
        honestly no form, rather than a fake object blob."""
        observed = await self.observe()
        values = (observed or {}).get("values") or {}
        if not values:
            self._schema = {}
            return {}
        directives = config_schema.catalog_for_path(self.path, config_schema.load_catalog(self._settings))
        self._schema = config_schema.derive_schema(values, directives)
        return self._schema

    def schema(self) -> dict[str, Any]:
        """Sync half of the Resource contract — serves what schema_async cached
        (same pattern as RoleResource, whose doc also lives behind I/O)."""
        return self._schema

    async def _observed_entry(self) -> dict[str, Any] | None:
        data = await self._client.state_observed()
        observed = data.get("observed", data) if isinstance(data, dict) else {}
        for it in observed.get("config") or []:
            if isinstance(it, dict) and it.get("path") == self.path:
                return it
        return None

    async def observe(self) -> dict[str, Any] | None:
        it = await self._observed_entry()
        if it is None:
            return None
        values = it.get("values") or {}
        # flat_values feeds the form; the index is what makes writing back exact.
        flat, index = config_schema.flatten(values)
        self._index = index
        return {"path": self.path, "format": it.get("format"),
                "separator": it.get("separator"), "values": values, "flat_values": flat}

    def _resource_doc(self, desired: dict[str, Any], observed: dict[str, Any] | None) -> dict[str, Any]:
        """Build the one-config-resource document the agent state API expects,
        taking format/separator from the observed file when the caller omits them.

        `values` may arrive FLAT (dotted keys from the per-directive form) or already
        nested (API/MCP callers): `inflate` resolves each key through the index of
        exact original segments — never by splitting on "." (real directive names
        contain dots)."""
        res: dict[str, Any] = {
            "type": "config", "path": self.path,
            "format": desired.get("format") or (observed or {}).get("format"),
            "values": config_schema.inflate(
                desired.get("values") or {}, self._index, (observed or {}).get("values")),
        }
        sep = desired.get("separator") or (observed or {}).get("separator")
        if sep:
            res["separator"] = sep
        return res

    async def plan(self, desired: dict[str, Any]) -> dict[str, Any]:
        observed = await self.observe()
        res = self._resource_doc(desired, observed)
        result = await self._client.state_plan({"resources": [res]})
        # extract the change for this path from the agent's plan
        change = next((c for c in (result.get("changes") or []) if c.get("path") == self.path), None)
        # The agent reports one change per RESOURCE, so for a sectioned file its
        # `changed` map is section-level ({} → {}). Re-diff both sides flat so the
        # node shows "Journal.Storage: auto → persistent"; keep the raw map too.
        raw_changed = (change or {}).get("changed", {})
        flat_diff = config_schema.flat_changed(
            (change or {}).get("before"), (change or {}).get("after"))
        return {
            "resource_key": self.resource_key,
            "action": (change or {}).get("action", "noop"),
            "changed": flat_diff or raw_changed,
            "changed_raw": raw_changed,
            "changed_count": result.get("changed_count", 0),
            "observed": observed,
            "desired": desired,
            "delegated_to": "agent.state",
        }

    async def apply(self, desired: dict[str, Any], *, dry_run: bool = True,
                    note: str | None = None) -> dict[str, Any]:
        observed = await self.observe()
        res = self._resource_doc(desired, observed)
        result = await self._client.state_apply({"resources": [res]}, dry_run=dry_run)
        plan = result.get("plan") if isinstance(result.get("plan"), dict) else result
        return {
            "dry_run": dry_run,
            "ok": True,
            "generation": result.get("generation"),   # host-scoped (agent store)
            "generation_scope": "host",
            "plan": plan,
            "delegated_to": "agent.state",
        }

    async def generations(self) -> list[dict[str, Any]]:
        """The HOST's config generations (agent store) — shared across all config
        files, not per-file. Newest first, adapted to the Resource shape."""
        data = await self._client.state_generations()
        gens = data.get("generations", data) if isinstance(data, dict) else []
        out = []
        for g in gens if isinstance(gens, list) else []:
            out.append({
                "generation": g.get("number") if "number" in g else g.get("generation"),
                "note": f"{g.get('resources', '?')} resources · host-scoped",
                "applied_at": g.get("applied_at"),
                "spec": {"hash": g.get("hash")},
            })
        return out

    async def rollback(self, generation: int) -> dict[str, Any]:
        """Roll the HOST's config back to a generation (agent store)."""
        result = await self._client.state_rollback(generation, dry_run=False)
        return {"ok": True, "generation": result.get("generation"),
                "generation_scope": "host", "plan": result.get("plan"),
                "delegated_to": "agent.state"}
