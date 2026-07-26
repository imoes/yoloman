"""DockerContainer — the first full Resource implementation (docs/resource-protocol.md).

Wraps the existing docker_app verbs (inspect/deploy) behind the four-verb Resource
contract and adds DB-backed generations + rollback — which the docker tier lacked.
Same observe→plan→apply→rollback the agent state store gives native config, now
for containers, and the exact shape a Workflow-Designer node will drive.
"""
from __future__ import annotations

from typing import Any

from bossman.services.docker_app import deploy_container, inspect_containers
from bossman.services.resources import base

# The fields that define a container (also the form schema for a canvas node).
_FIELDS = ["image", "ports", "env", "volumes", "restart"]
_SCHEMA: dict[str, Any] = {
    "name": {"type": "string", "required": True, "description": "container name"},
    "image": {"type": "string", "required": True, "description": "e.g. nginx:1.27"},
    "ports": {"type": "list", "description": "host:container, e.g. 8080:80"},
    "env": {"type": "object", "description": "environment variables"},
    "volumes": {"type": "list", "description": "host:container[:ro] bind mounts"},
    "restart": {"type": "string", "enum": ["no", "on-failure", "always", "unless-stopped"],
                "default": "unless-stopped"},
}


class DockerContainerResource:
    resource_type = "docker_container"

    def __init__(self, session, agent, client_factory, settings, name: str):
        self._session = session
        self._agent = agent
        self._cf = client_factory
        self._settings = settings
        self.name = name
        self.resource_key = f"docker:{agent.id}:{name}"

    def schema(self) -> dict[str, Any]:
        return _SCHEMA

    async def observe(self) -> dict[str, Any] | None:
        """Current container spec (docker inspect), or None if it doesn't exist."""
        insp = await inspect_containers(self._agent, self._cf, self._settings)
        for c in insp.get("containers") or []:
            if c.get("name") == self.name:
                return {k: c.get(k) for k in ("name", *_FIELDS)}
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
        dep = await deploy_container(
            self._agent, self._cf, self._settings, name=self.name, image=desired.get("image", ""),
            ports=desired.get("ports"), env=desired.get("env"), volumes=desired.get("volumes"),
            restart=desired.get("restart") or "unless-stopped", dry_run=False,
        )
        if not dep.get("ok"):
            return {"dry_run": False, "ok": False, "error": (dep.get("stderr") or "deploy failed")[:300], "plan": plan}
        gen = await base.record_generation(
            self._session, self.resource_key, self.resource_type,
            {"name": self.name, **{f: desired.get(f) for f in _FIELDS}}, note=note,
        )
        return {"dry_run": False, "ok": True, "generation": gen, "plan": plan}

    async def generations(self) -> list[dict[str, Any]]:
        return await base.list_generations(self._session, self.resource_key)

    async def rollback(self, generation: int) -> dict[str, Any]:
        spec = await base.get_generation_spec(self._session, self.resource_key, generation)
        if spec is None:
            return {"ok": False, "error": f"no generation {generation} for {self.name}"}
        # forward-converge: re-apply the old spec, recorded as a NEW generation.
        return await self.apply(spec, dry_run=False, note=f"rollback to gen {generation}")
