"""System discovery (test-systems Block 1, read-only half) — propose a `System`
(a named set of apps + wiring, the unit ABOVE a single host, see
docs/test-systems.md) from a seed host's LIVE state, WITHOUT persisting anything.

A proposed System is what the user confirms + names before it is stored; keeping
discovery read-only first lets us validate the shape (members, wiring) before the
DB tables land. Members come from all three tiers observed on the host:
docker containers, Helm releases, and native services that map to catalog apps.
Wiring (edges) is derived from docker-compose project membership — containers in
the same compose project are related.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from bossman.config import Settings
from bossman.services.docker_app import inspect_containers
from bossman.services.helm_app import list_releases
from bossman.services.server_document import build_server_document


def _catalog_ids(settings: Settings) -> set[str]:
    path = Path(settings.config_templates_dir).parent / "package_catalog.json"
    try:
        data = json.loads(path.read_text())
        return set(data.keys()) if isinstance(data, dict) else set()
    except (OSError, ValueError):
        return set()


async def propose_system(session, agent, client_factory, settings, *, name: str | None = None) -> dict[str, Any]:
    """Propose (not persist) a System seeded from `agent`: its apps across the
    three tiers + compose-derived wiring."""
    members: list[dict[str, Any]] = []

    # docker tier — every container is a member (compose provenance = its role)
    compose_projects: dict[str, list[str]] = {}
    try:
        insp = await inspect_containers(agent, client_factory, settings)
        for c in insp.get("containers") or []:
            mid = f"docker/{c.get('name')}"
            members.append({
                "id": mid, "target": "docker", "app": c.get("name"), "image": c.get("image"),
                "role_in_system": c.get("compose_service") or c.get("name"),
                "compose_project": c.get("compose_project"), "compose_file": c.get("compose_file"),
            })
            proj = c.get("compose_project")
            if proj:
                compose_projects.setdefault(proj, []).append(mid)
    except Exception:  # noqa: BLE001 — no docker on host
        pass

    # k8s tier — deployed Helm releases
    try:
        rel = await list_releases(agent, client_factory, settings)
        for r in rel.get("releases") or []:
            members.append({
                "id": f"k8s/{r.get('name')}", "target": "k8s", "app": r.get("name"),
                "chart": r.get("chart"), "role_in_system": r.get("name"),
            })
    except Exception:  # noqa: BLE001 — no cluster
        pass

    # native tier — observed services that map to a known catalog app
    try:
        doc = await build_server_document(session, agent, client_factory, settings, include={"config"})
        observed = (doc.get("config") or {}).get("observed") or {}
        svcs = observed.get("services") if isinstance(observed, dict) else None
        catalog = _catalog_ids(settings)
        seen: set[str] = set()
        for s in svcs or []:
            raw = s.get("name") if isinstance(s, dict) else s
            base = str(raw or "").removesuffix(".service")
            if base in catalog and base not in seen:
                seen.add(base)
                members.append({"id": f"native/{base}", "target": "native", "app": base, "role_in_system": base})
    except Exception:  # noqa: BLE001
        pass

    # wiring — chain members within each docker-compose project (real, cheap edges)
    edges: list[dict[str, str]] = []
    for proj, ids in compose_projects.items():
        for i in range(len(ids) - 1):
            edges.append({"from": ids[i], "to": ids[i + 1], "kind": f"compose:{proj}"})

    return {
        "proposed": True,
        "seed": {"id": str(agent.id), "name": agent.name},
        "name": name or f"{agent.name}-system",
        "members": members,
        "member_count": len(members),
        "edges": edges,
        "note": "Proposed from live state — confirm + name to persist (persistence is a follow-up slice).",
    }
