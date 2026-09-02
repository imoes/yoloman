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

from bossman.services import config_schema, helm_app
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
        self._index: dict[str, list[str]] = {}   # flat key → exact segments
        self._schema: dict[str, Any] = {}

    async def schema_async(self) -> dict[str, Any]:
        """The release's value surface BROKEN OUT — one typed field per value, not
        one JSON blob. Derived from `helm get values -a`, i.e. the chart defaults
        merged with the user's overrides = every value actually in effect, so the
        form shows what CAN be set and what it currently is.

        Uses the same generic flatten/derive helpers as the config tier, so a value
        key containing dots (`kubernetes.io/ingress.class`) still round-trips
        exactly — the index keeps each key's original segments."""
        allv = await self._all_values()
        if not allv:
            self._schema = {}
            return {}
        flat, index = config_schema.flatten(allv)
        self._index = index
        self._schema = config_schema.derive_schema(allv)
        return self._schema

    def schema(self) -> dict[str, Any]:
        """Sync half of the contract — the static shape until schema_async ran."""
        return self._schema or _SCHEMA

    async def _all_values(self) -> dict[str, Any]:
        """ALL values in effect (chart defaults + overrides): `helm get values -a`.
        This is the full option surface the form should expose."""
        data = await _cmd(self._cf(self._agent, self._settings),
                          ["helm", "get", "values", self.name, "-n", self.namespace, "-a", "-o", "yaml"])
        if data.get("rc") != 0:
            return {}
        try:
            parsed = yaml.safe_load(data.get("stdout") or "") or {}
            return parsed if isinstance(parsed, dict) else {}
        except yaml.YAMLError:
            return {}

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
                allv = await self._all_values()
                flat, index = config_schema.flatten(allv)
                self._index = index
                return {
                    "name": self.name, "namespace": self.namespace,
                    "chart": r.get("chart"), "status": r.get("status"), "revision": r.get("revision"),
                    "values": await self._live_values(),   # user-supplied overrides
                    "all_values": allv,                     # defaults + overrides
                    "flat_values": flat,                    # what the per-value form binds to
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
        # the form posts FLAT dotted keys; inflate through the index so a key that
        # itself contains dots (kubernetes.io/…) is restored exactly
        vals = config_schema.inflate(desired.get("values") or {}, self._index,
                                     (plan.get("observed") or {}).get("all_values"))
        values_yaml = yaml.safe_dump(vals, default_flow_style=False, sort_keys=False) if vals else ""
        # `helm upgrade` needs the chart REFERENCE, which a deployed release does not
        # expose (helm list reports "name-version"). Editing values from the node
        # therefore reuses the chart recorded by the last apply.
        chart = desired.get("chart") or await self._last_chart()
        if not chart:
            return {"dry_run": False, "ok": False, "plan": plan,
                    "error": "no chart reference: this release was not deployed through the resource API, "
                             "so pass `chart` explicitly (helm upgrade needs it)"}
        res = await helm_app.install_release(
            self._agent, self._cf, self._settings, name=self.name, chart=chart,
            values_yaml=values_yaml, namespace=self.namespace, create_namespace=True,
        )
        if not res.get("ok"):
            return {"dry_run": False, "ok": False, "error": (res.get("error") or "helm install failed")[:300], "plan": plan}
        gen = await base.record_generation(
            self._session, self.resource_key, self.resource_type,
            {"name": self.name, "namespace": self.namespace,
             "chart": chart, "values": desired.get("values") or {}}, note=note,
        )
        return {"dry_run": False, "ok": True, "generation": gen, "plan": plan}

    async def _last_chart(self) -> str:
        """The chart reference from the most recent recorded apply."""
        for gen in await base.list_generations(self._session, self.resource_key):
            chart = (gen.get("spec") or {}).get("chart")
            if chart:
                return str(chart)
        return ""

    async def generations(self) -> list[dict[str, Any]]:
        return await base.list_generations(self._session, self.resource_key)

    async def rollback(self, generation: int) -> dict[str, Any]:
        spec = await base.get_generation_spec(self._session, self.resource_key, generation)
        if spec is None:
            return await base.no_such_generation(self._session, self.resource_key, generation, self.name)
        return await self.apply(spec, dry_run=False, note=f"rollback to gen {generation}")
