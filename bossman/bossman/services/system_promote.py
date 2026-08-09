"""System promote (test-systems Block 6) — apply a rehearsed change to PROD as
ONE atomic change-set with a single rollback boundary across members.

Only promotes on a GREEN rehearsal (rehearse_first, the safety gate). The change
is applied to each prod member preserving its FULL current spec (ports/env/
volumes) with just the new image swapped in — recovered via docker inspect, so a
promote never destroys the container's other settings. If any member's apply
fails, every already-applied member is rolled back to its captured prior spec —
the atomic boundary (docs/test-systems.md, gap #5).
"""
from __future__ import annotations

from typing import Any

from bossman.db.models import System
from bossman.services.docker_app import deploy_container, inspect_containers
from bossman.services.system_rehearsal import rehearse


async def promote(system: System, target_agent, image_overrides: dict[str, str], client_factory, settings, *,
                  rehearse_first: bool = True, dry_run: bool = False) -> dict[str, Any]:
    """Promote an image change to the System's prod members on target_agent.
    Gated on a green rehearsal (unless disabled). Dry-run returns the planned
    change-set (from→to) without applying."""
    overrides = image_overrides or {}
    if not overrides:
        return {"promoted": False, "reason": "no change (empty image_overrides)"}

    # 1. safety gate — rehearse the change in a sandbox first; refuse if red.
    rehearsal = None
    if rehearse_first and not dry_run:
        rehearsal = await rehearse(system, target_agent, client_factory, settings,
                                   image_overrides=overrides, teardown=True)
        if not rehearsal.get("passed"):
            return {"promoted": False, "reason": "rehearsal failed — not promoting to prod",
                    "rehearsal": rehearsal}

    # 2. recover each prod member's FULL current spec (so we swap ONLY the image)
    insp = await inspect_containers(target_agent, client_factory, settings)
    by_name = {c.get("name"): c for c in insp.get("containers") or []}

    change_set: list[dict[str, Any]] = []
    for m in system.members:
        if m.target != "docker" or m.app not in overrides:
            continue
        cur = by_name.get(m.app)
        if cur is None:
            change_set.append({"member": m.app, "error": "no prod container found to promote"})
            continue
        change_set.append({
            "member": m.app, "container": m.app,
            "from_image": cur.get("image"), "to_image": overrides[m.app],
            "_from_spec": cur,   # full spec = the rollback point (stripped from the response)
        })

    appliable = [c for c in change_set if "error" not in c]
    if dry_run or not appliable:
        return {"promoted": False, "dry_run": dry_run, "rehearsal": rehearsal,
                "change_set": [_public(c) for c in change_set]}

    # 3. apply as an atomic change-set; roll back all-applied on any failure
    applied: list[dict[str, Any]] = []
    for c in appliable:
        spec = c["_from_spec"]
        res = await deploy_container(
            target_agent, client_factory, settings, name=c["container"], image=c["to_image"],
            ports=spec.get("ports"), env=spec.get("env"), volumes=spec.get("volumes"),
            restart=spec.get("restart") or "unless-stopped", dry_run=False,
        )
        c["ok"] = bool(res.get("ok"))
        if not res.get("ok"):
            c["error"] = (res.get("stderr") or "deploy failed")[:200]
            rolled = await _rollback(applied, target_agent, client_factory, settings)
            return {"promoted": False, "reason": "apply failed — rolled back the change-set",
                    "failed_member": c["member"], "rolled_back": rolled,
                    "change_set": [_public(x) for x in change_set]}
        applied.append(c)

    return {"promoted": True, "target": {"id": str(target_agent.id), "name": target_agent.name},
            "applied_count": len(applied), "rehearsal_passed": rehearsal.get("passed") if rehearsal else None,
            "change_set": [_public(c) for c in change_set]}


async def _rollback(applied: list[dict[str, Any]], target_agent, client_factory, settings) -> list[str]:
    """Redeploy each already-applied member back to its captured prior spec."""
    rolled: list[str] = []
    for c in applied:
        spec = c["_from_spec"]
        await deploy_container(
            target_agent, client_factory, settings, name=c["container"], image=spec.get("image"),
            ports=spec.get("ports"), env=spec.get("env"), volumes=spec.get("volumes"),
            restart=spec.get("restart") or "unless-stopped", dry_run=False,
        )
        rolled.append(c["container"])
    return rolled


def _public(c: dict[str, Any]) -> dict[str, Any]:
    """Drop the internal _from_spec (full container config) from the response."""
    return {k: v for k, v in c.items() if not k.startswith("_")}
