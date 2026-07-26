"""HelmRelease — the k8s tier behind the Resource/Deployable contract
(docs/resource-protocol.md). Same schema/observe/plan/apply/rollback + DB-backed
generations as DockerContainer, so a Helm release gets the uniform versioned
lifecycle (and, later, a canvas node) exactly like the docker tier.

Desired spec = {chart, namespace, values} (values a nested dict). observe reads
the live release (helm list) + its user-supplied values (helm get values); plan
diffs chart + values; apply = helm upgrade --install and records a generation;
rollback re-applies an earlier spec as a NEW generation (forward-converge, like
the docker/config model — not helm's own revision rollback, so the model stays
uniform across tiers).
"""
from __future__ import annotations

from typing import Any

import yaml

from bossman.services import helm_app
from bossman.services.resources import base

_FIELDS = ["chart", "values"]
_SCHEMA: dict[str, Any] = {
    "name": {"type": "string", "required": True, "description": "release name"},
    "chart": {"type": "string", "required": True, "description": "e.g. bitnami/nginx or a local path"},
    "namespace": {"type": "string", "default": "default"},
    "values": {"type": "object", "description": "chart values (overrides)"},
}


async def _cmd(client, argv: list[str]) -> dict[str, Any]:
    r = await client.call_tool("command", {"argv": argv})
    return (r or {}).get("data") if isinstance(r, dict) else {}


class HelmReleaseResource:
    resource_type = "helm_release"

    def __init__(self, session, agent, client_factory, settings, name: str, namespace: str = "default"):
        self._session = session
        self._agent = agent
        self._cf = client_factory
        self._settings = settings
        self.name = name
        self.namespace = namespace or "default"
        self.resource_key = f"helm:{agent.id}:{self.namespace}:{name}"

    def schema(self) -> dict[str, Any]:
        return _SCHEMA

    async def _live_values(self) -> dict[str, Any]:
        """User-supplied values of the deployed release (helm get values)."""
        data = await _cmd(self._cf(self._agent, self._settings),
                          ["helm", "get", "values", self.name, "-n", self.namespace, "-o", "yaml"])
        if data.get("rc") != 0:
            return {}
        try:
            parsed = yaml.safe_load(data.get("stdout") or "") or {}
            # helm prints "null" / "USER-SUPPLIED VALUES:" noise for empty → normalise
            return parsed if isinstance(parsed, dict) else {}
        except yaml.YAMLError:
            return {}

    async def observe(self) -> dict[str, Any] | None:
        rel = await helm_app.list_releases(self._agent, self._cf, self._settings)
        for r in rel.get("releases") or []:
            if r.get("name") == self.name and r.get("namespace") == self.namespace:
                return {
                    "name": self.name, "namespace": self.namespace,
                    "chart": r.get("chart"), "status": r.get("status"), "revision": r.get("revision"),
                    "values": await self._live_values(),
                }
        return None

    async def plan(self, desired: dict[str, Any]) -> dict[str, Any]:
        observed = await self.observe()
        d = base.diff_specs(observed, desired, _FIELDS)
        d["resource_key"] = self.resource_key
        d["observed"] = observed
        d["desired"] = desired
        return d

    async def apply(self, desired: dict[str, Any], *, dry_run: bool = True,
                    note: str | None = None) -> dict[str, Any]:
        plan = await self.plan(desired)
        if dry_run:
            return {"dry_run": True, "plan": plan}
        values_yaml = yaml.safe_dump(desired.get("values") or {}, default_flow_style=False, sort_keys=False) \
            if desired.get("values") else ""
        res = await helm_app.install_release(
            self._agent, self._cf, self._settings, name=self.name, chart=desired.get("chart", ""),
            values_yaml=values_yaml, namespace=self.namespace, create_namespace=True,
        )
        if not res.get("ok"):
            return {"dry_run": False, "ok": False, "error": (res.get("error") or "helm install failed")[:300], "plan": plan}
        gen = await base.record_generation(
            self._session, self.resource_key, self.resource_type,
            {"name": self.name, "namespace": self.namespace,
             "chart": desired.get("chart"), "values": desired.get("values") or {}}, note=note,
        )
        return {"dry_run": False, "ok": True, "generation": gen, "plan": plan}

    async def generations(self) -> list[dict[str, Any]]:
        return await base.list_generations(self._session, self.resource_key)

    async def rollback(self, generation: int) -> dict[str, Any]:
        spec = await base.get_generation_spec(self._session, self.resource_key, generation)
        if spec is None:
            return {"ok": False, "error": f"no generation {generation} for {self.name}"}
        return await self.apply(spec, dry_run=False, note=f"rollback to gen {generation}")
