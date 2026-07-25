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

    services = observed.get("services") or []
    return {
        "source": {"id": str(agent.id), "name": agent.name},
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "resources": resources,
        "resource_count": len(resources),
        "skipped_raw": skipped,
        "services": [s.get("name") if isinstance(s, dict) else s for s in services][:80],
        "note": "Portable native config spec. Apply to a target host with /materialize (dry-run first).",
    }


async def materialize_spec(session, target_agent, client_factory, settings,
                           spec: dict[str, Any], dry_run: bool = True) -> dict[str, Any]:
    """Apply a portable spec's config resources to `target_agent`. Dry-run by
    default: returns the plan (what WOULD change on the target) without writing —
    the safe preview for clone/DR before committing."""
    resources = spec.get("resources") or []
    result: dict[str, Any] = {
        "target": {"id": str(target_agent.id), "name": target_agent.name},
        "source": spec.get("source"),
        "dry_run": dry_run,
        "resource_count": len(resources),
    }
    try:
        applied = await client_factory(target_agent, settings).state_apply(
            {"resources": resources}, dry_run=dry_run
        )
        plan = applied.get("plan") if isinstance(applied.get("plan"), dict) else applied
        result["changed_count"] = plan.get("changed_count") if isinstance(plan, dict) else None
        result["plan"] = plan
        result["generation"] = applied.get("generation")
    except Exception as exc:  # noqa: BLE001
        result["error"] = str(exc)[:300]
    return result
