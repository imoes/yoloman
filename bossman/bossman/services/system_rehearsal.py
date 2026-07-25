"""System rehearsal (test-systems Block 5) — the rehearsal plane. Bring a
System's members up for REAL in a disposable sandbox, optionally with a proposed
change (image override), health-gate them with the apps' own checks, then tear
the sandbox down. This is what turns a syntactic dry-run into a behavioral
rehearsal: "does this system actually come up (with my change) before I touch
prod?" (docs/test-systems.md).

MVP: docker members (the cheap, disposable tier). Each member is deployed with a
sandbox name prefix; the health gate is `docker inspect .State` (Running + the
container's own HEALTHCHECK status where present). Member-SCOPED (only the
System's members, not the whole seed host).
"""
from __future__ import annotations

import asyncio
import json
from typing import Any

from bossman.db.models import System
from bossman.services.docker_app import deploy_container, remove_container
from bossman.services.system_clone import _sandbox_prefix


async def _container_state(client, name: str) -> dict[str, Any]:
    r = await client.call_tool("command", {"argv": ["docker", "inspect", "--format", "{{json .State}}", name]})
    data = (r or {}).get("data") if isinstance(r, dict) else {}
    st: dict[str, Any] = {}
    try:
        st = json.loads((data.get("stdout") or "").strip() or "{}")
    except ValueError:
        st = {}
    return {
        "running": bool(st.get("Running")),
        "status": st.get("Status"),
        "health": (st.get("Health") or {}).get("Status"),  # None if the image has no HEALTHCHECK
    }


async def rehearse(system: System, target_agent, client_factory, settings, *,
                   image_overrides: dict[str, str] | None = None, teardown: bool = True,
                   settle_seconds: float = 2.0) -> dict[str, Any]:
    """Rehearse `system` in a sandbox on `target_agent`: deploy its docker members
    (with optional image overrides = the change under test), health-check them,
    then tear down. Returns a pass/fail report."""
    overrides = image_overrides or {}
    members = [m for m in system.members if m.target == "docker"]
    if not members:
        return {"error": "no docker members to rehearse", "system": system.name}

    prefix = _sandbox_prefix(system.name)
    client = client_factory(target_agent, settings)
    deployed: list[str] = []
    checks: list[dict[str, Any]] = []

    # 1. bring the sandbox up (real) — one container per member, prefixed
    for m in members:
        sandbox_name = f"{prefix}-{m.app}"
        image = overrides.get(m.app) or (m.config or {}).get("image")
        if not image:
            checks.append({"member": m.app, "error": "member has no image"})
            continue
        dep = await deploy_container(target_agent, client_factory, settings,
                                     name=sandbox_name, image=image, ports=[], env={},
                                     restart="no", dry_run=False)
        if dep.get("ok"):
            deployed.append(sandbox_name)
        else:
            checks.append({"member": m.app, "container": sandbox_name, "deployed": False,
                           "error": (dep.get("stderr") or "deploy failed")[:200]})

    # 2. let them settle, then health-gate
    if deployed:
        await asyncio.sleep(settle_seconds)
    for name in deployed:
        state = await _container_state(client, name)
        # pass = running AND (no healthcheck OR healthy)
        ok = state["running"] and state["health"] in (None, "healthy")
        checks.append({"container": name, "deployed": True, **state, "passed": ok})

    # 3. teardown the disposable sandbox
    torn: list[str] = []
    if teardown:
        for name in deployed:
            await remove_container(target_agent, client_factory, settings, name=name)
            torn.append(name)

    graded = [c for c in checks if "passed" in c]
    passed = bool(graded) and all(c["passed"] for c in checks if "passed" in c) and not any("error" in c for c in checks)
    return {
        "system": {"id": str(system.id), "name": system.name},
        "target": {"id": str(target_agent.id), "name": target_agent.name},
        "sandbox_prefix": prefix,
        "change": {"image_overrides": overrides} if overrides else None,
        "passed": passed,
        "checks": checks,
        "torn_down": torn,
    }
