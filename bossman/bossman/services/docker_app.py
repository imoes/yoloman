"""Docker app target (app-system increment 2) — the sandboxed single-host tier
of the unified App model (native | docker | k8s, see docs/app-model.md). Deploy /
configure / list / remove a container FROM VALUES on one host, via the agent's
`command` tool (docker is on the host). Same lifecycle grammar as the native and
Helm tiers; this is what "materialize as a container" (cross-tier reproduce)
builds on.

MVP: a container = {name, image, ports, env, volumes, restart}. Deploy is
idempotent (replace a same-named container). Read-only ops (list/inspect) and a
dry-run (show the command) are safe; deploy/remove mutate and need the agent's
write capability.
"""
from __future__ import annotations

import json
import shlex
from typing import Any


async def _run(client, argv: list[str]) -> dict[str, Any]:
    r = await client.call_tool("command", {"argv": argv})
    return (r or {}).get("data") if isinstance(r, dict) else {}


def _run_argv(name: str, image: str, ports, env, volumes, restart: str) -> list[str]:
    argv = ["docker", "run", "-d", "--name", name, "--restart", restart or "unless-stopped"]
    for p in ports or []:
        if isinstance(p, dict) and p.get("host") and p.get("container"):
            argv += ["-p", f"{p['host']}:{p['container']}"]
    for k, v in (env or {}).items():
        argv += ["-e", f"{k}={v}"]
    for vol in volumes or []:
        if vol:
            argv += ["-v", str(vol)]
    argv.append(image)
    return argv


async def deploy_container(agent, client_factory, settings, *, name: str, image: str,
                           ports=None, env=None, volumes=None, restart: str = "unless-stopped",
                           dry_run: bool = False) -> dict[str, Any]:
    """Deploy (idempotently replace) a container from values. dry_run shows the
    command without running it."""
    argv = _run_argv(name, image, ports, env, volumes, restart)
    cmd = " ".join(shlex.quote(a) for a in argv)
    result: dict[str, Any] = {"agent": {"id": str(agent.id), "name": agent.name},
                              "container": name, "image": image, "command": cmd, "dry_run": dry_run}
    if dry_run:
        return result
    client = client_factory(agent, settings)
    # Replace any same-named container, then run — idempotent redeploy.
    replace = f"docker rm -f {shlex.quote(name)} >/dev/null 2>&1 || true; {cmd}"
    data = await _run(client, ["sh", "-c", replace])
    result["rc"] = data.get("rc")
    result["stdout"] = (data.get("stdout") or "").strip()[:200]
    result["stderr"] = (data.get("stderr") or "").strip()[:300]
    result["ok"] = (data.get("rc") == 0)
    return result


async def list_containers(agent, client_factory, settings) -> dict[str, Any]:
    """Running/known containers on the host (docker ps -a, JSON per line)."""
    client = client_factory(agent, settings)
    data = await _run(client, ["docker", "ps", "-a", "--format", "{{json .}}"])
    out = []
    for line in (data.get("stdout") or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            c = json.loads(line)
            out.append({"name": c.get("Names"), "image": c.get("Image"),
                        "status": c.get("Status"), "ports": c.get("Ports"), "state": c.get("State")})
        except ValueError:
            continue
    return {"agent": {"id": str(agent.id), "name": agent.name}, "containers": out, "count": len(out)}


async def remove_container(agent, client_factory, settings, *, name: str) -> dict[str, Any]:
    """Force-remove a container by name."""
    client = client_factory(agent, settings)
    data = await _run(client, ["docker", "rm", "-f", name])
    return {"agent": {"id": str(agent.id), "name": agent.name}, "container": name,
            "rc": data.get("rc"), "ok": (data.get("rc") == 0), "stderr": (data.get("stderr") or "").strip()[:300]}
