"""System clone (test-systems Block 2, config axis) — clone a System's seed host
into a disposable sandbox, so a change can be rehearsed there before prod (see
docs/test-systems.md). DECISION: cross-tier default — a native app is cloned as
a container; the sandbox is cheap + disposable.

Reuses reproduce (export_server_spec spans native config + docker containers) and
materialize_spec (config → agent state store, docker_container → docker deploy).
The clone TRANSFORMS the exported spec for a sandbox:
  - docker container names are prefixed (sbx-<system>-…) so they don't collide
    with the originals, and host port bindings are dropped (a sandbox needs no
    host ports for a config/health rehearsal; avoids port clashes).
Dry-run by default: preview the whole clone (config plan + docker run commands)
before any write. Secrets are NOT cloned here — fresh sandbox secrets from the
password DB are Block 3.
"""
from __future__ import annotations

import re
from typing import Any

from bossman.db.models import Agent, System
from bossman.services.server_reproduce import export_server_spec, materialize_spec


def _sandbox_prefix(system_name: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9_.-]+", "-", system_name).strip("-").lower() or "system"
    return f"sbx-{slug}"


def _transform_for_sandbox(spec: dict[str, Any], prefix: str) -> dict[str, Any]:
    """Rewrite an exported spec so it materializes into an isolated sandbox:
    prefix docker container names, drop host port bindings."""
    resources = []
    for r in spec.get("resources") or []:
        if r.get("type") == "docker_container":
            r = {**r, "name": f"{prefix}-{r.get('name')}", "ports": []}
        resources.append(r)
    return {**spec, "resources": resources, "sandbox_prefix": prefix}


async def clone_system(session, system: System, target_agent: Agent, client_factory, settings,
                       dry_run: bool = True) -> dict[str, Any]:
    """Clone `system`'s seed host into a sandbox on `target_agent`. Dry-run by
    default (preview only)."""
    seed = await session.get(Agent, system.seed_agent_id) if system.seed_agent_id else None
    if seed is None:
        return {"error": "system has no seed host to clone from", "system": system.name}

    spec = await export_server_spec(session, seed, client_factory, settings)
    prefix = _sandbox_prefix(system.name)
    sandbox_spec = _transform_for_sandbox(spec, prefix)
    result = await materialize_spec(session, target_agent, client_factory, settings, sandbox_spec, dry_run=dry_run)
    return {
        "system": {"id": str(system.id), "name": system.name},
        "seed": {"id": str(seed.id), "name": seed.name},
        "target": {"id": str(target_agent.id), "name": target_agent.name},
        "sandbox_prefix": prefix,
        "dry_run": dry_run,
        "source_resource_count": spec.get("resource_count"),
        "materialize": result,
    }
