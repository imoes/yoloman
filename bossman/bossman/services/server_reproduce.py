"""Reproducibility (killer-feature increment b, native MVP) — because a server
IS a document, capture a running one as a PORTABLE spec and re-materialize it on
another host. That's clone / golden-from-running / DR, all from live state.

MVP scope: the structured config (codec'd files → desired config resources that
re-apply cleanly). Codec-less/raw files and the role/package layer are follow-ups
(and cross-tier docker/k8s builds on the app-system). Materialize is DRY-RUN by
default — you preview the plan on the target before any write.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from bossman.services.docker_app import deploy_container, inspect_containers
from bossman.services.server_document import build_server_document


async def export_server_spec(session, agent, client_factory, settings) -> dict[str, Any]:
    """A portable spec of `agent`: its structured config as re-appliable config
    resources (+ the observed service list, for context)."""
    doc = await build_server_document(session, agent, client_factory, settings, include={"config"})
    observed = (doc.get("config") or {}).get("observed") or {}
    items = observed.get("config") if isinstance(observed.get("config"), list) else []

    resources: list[dict[str, Any]] = []
    skipped: list[str] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        path, fmt, vals = it.get("path"), it.get("format"), it.get("values")
        if path and fmt and isinstance(vals, dict) and vals:
            res: dict[str, Any] = {"type": "config", "path": path, "format": fmt, "values": vals}
            if it.get("separator"):
                res["separator"] = it["separator"]
            resources.append(res)
        elif path:
            skipped.append(path)   # codec-less/raw file — not portable as values (follow-up)

    # Docker axis: every container recovered as a re-appliable docker_container
    # resource (same shape deploy_container consumes) + its compose provenance,
    # so the reproduced spec spans native config AND the docker tier.
    compose_files: list[str] = []
    try:
        insp = await inspect_containers(agent, client_factory, settings)
        for c in insp.get("containers") or []:
            resources.append({
                "type": "docker_container",
                "name": c.get("name"), "image": c.get("image"),
                "ports": c.get("ports") or [], "env": c.get("env") or {},
                "volumes": c.get("volumes") or [], "restart": c.get("restart") or "unless-stopped",
                "compose_file": c.get("compose_file"),
            })
        compose_files = insp.get("compose_files") or []
    except Exception:  # noqa: BLE001
        pass  # no docker on the host → native-only spec

    services = observed.get("services") or []
    return {
        "source": {"id": str(agent.id), "name": agent.name},
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "resources": resources,
        "resource_count": len(resources),
        "skipped_raw": skipped,
        "compose_files": compose_files,
        "services": [s.get("name") if isinstance(s, dict) else s for s in services][:80],
        "note": "Portable spec (native config + docker containers). Apply to a target with /materialize (dry-run first).",
    }


async def materialize_spec(session, target_agent, client_factory, settings,
                           spec: dict[str, Any], dry_run: bool = True) -> dict[str, Any]:
    """Apply a portable spec's config resources to `target_agent`. Dry-run by
    default: returns the plan (what WOULD change on the target) without writing —
    the safe preview for clone/DR before committing."""
    resources = spec.get("resources") or []
    config_res = [r for r in resources if r.get("type") != "docker_container"]
    docker_res = [r for r in resources if r.get("type") == "docker_container"]
    result: dict[str, Any] = {
        "target": {"id": str(target_agent.id), "name": target_agent.name},
        "source": spec.get("source"),
        "dry_run": dry_run,
        "resource_count": len(resources),
    }
    # Native config resources → the agent's state store (generations + rollback).
    if config_res:
        try:
            applied = await client_factory(target_agent, settings).state_apply(
                {"resources": config_res}, dry_run=dry_run
            )
            plan = applied.get("plan") if isinstance(applied.get("plan"), dict) else applied
            result["changed_count"] = plan.get("changed_count") if isinstance(plan, dict) else None
            result["plan"] = plan
            result["generation"] = applied.get("generation")
        except Exception as exc:  # noqa: BLE001
            result["error"] = str(exc)[:300]
    # Docker containers → deploy on the target (dry-run shows the docker run cmd).
    if docker_res:
        containers: list[dict[str, Any]] = []
        for r in docker_res:
            try:
                d = await deploy_container(
                    target_agent, client_factory, settings,
                    name=r.get("name"), image=r.get("image"), ports=r.get("ports"),
                    env=r.get("env"), volumes=r.get("volumes"),
                    restart=r.get("restart") or "unless-stopped", dry_run=dry_run,
                )
                containers.append({"name": r.get("name"), "command": d.get("command"),
                                   "ok": d.get("ok"), "error": d.get("stderr")})
            except Exception as exc:  # noqa: BLE001
                containers.append({"name": r.get("name"), "error": str(exc)[:200]})
        result["docker"] = containers
        result["docker_count"] = len(containers)
    return result
