"""Tests for System promote (Block 6) — a rehearsed change applied to prod as an
atomic change-set: gated on a green rehearsal, preserves each container's full
spec (only the image swaps), and rolls the whole set back if any member fails."""
from __future__ import annotations

import types

import pytest

from bossman.services import system_promote


def _system(*apps):
    members = [types.SimpleNamespace(target="docker", app=a, config={}) for a in apps]
    return types.SimpleNamespace(id="s1", name="demo", members=members)


@pytest.mark.asyncio
async def test_promote_refuses_on_red_rehearsal(monkeypatch):
    async def red(*a, **k):
        return {"passed": False, "checks": [{"container": "sbx-demo-web", "passed": False}]}
    monkeypatch.setattr(system_promote, "rehearse", red)

    out = await system_promote.promote(_system("web"), types.SimpleNamespace(id="t", name="prod"),
                                       {"web": "nginx:bad"}, lambda a, s: None, settings=None)
    assert out["promoted"] is False and "rehearsal failed" in out["reason"]


@pytest.mark.asyncio
async def test_promote_applies_and_preserves_spec(monkeypatch):
    async def green(*a, **k):
        return {"passed": True}
    async def fake_inspect(agent, cf, s):
        return {"containers": [
            {"name": "web", "image": "nginx:1.27", "ports": [{"host": "80", "container": "80"}],
             "env": {"X": "1"}, "volumes": ["/data:/data"], "restart": "unless-stopped"},
        ]}
    deploys = []
    async def fake_deploy(agent, cf, s, *, name, image, ports, env, volumes, restart, dry_run):
        deploys.append({"name": name, "image": image, "ports": ports, "env": env, "volumes": volumes})
        return {"ok": True, "container": name}

    monkeypatch.setattr(system_promote, "rehearse", green)
    monkeypatch.setattr(system_promote, "inspect_containers", fake_inspect)
    monkeypatch.setattr(system_promote, "deploy_container", fake_deploy)

    out = await system_promote.promote(_system("web"), types.SimpleNamespace(id="t", name="prod"),
                                       {"web": "nginx:1.29"}, lambda a, s: None, settings=None)
    assert out["promoted"] is True and out["applied_count"] == 1
    cs = out["change_set"][0]
    assert cs["from_image"] == "nginx:1.27" and cs["to_image"] == "nginx:1.29"
    assert "_from_spec" not in cs                       # internal field stripped from response
    # the deploy carried the NEW image but PRESERVED ports/env/volumes
    d = deploys[0]
    assert d["image"] == "nginx:1.29"
    assert d["ports"] == [{"host": "80", "container": "80"}] and d["env"] == {"X": "1"} and d["volumes"] == ["/data:/data"]


@pytest.mark.asyncio
async def test_promote_dry_run_plans_without_applying(monkeypatch):
    async def fake_inspect(agent, cf, s):
        return {"containers": [{"name": "web", "image": "nginx:1.27"}]}
    called = {"deploy": 0}
    async def fake_deploy(*a, **k):
        called["deploy"] += 1
        return {"ok": True}
    monkeypatch.setattr(system_promote, "inspect_containers", fake_inspect)
    monkeypatch.setattr(system_promote, "deploy_container", fake_deploy)

    out = await system_promote.promote(_system("web"), types.SimpleNamespace(id="t", name="prod"),
                                       {"web": "nginx:1.29"}, lambda a, s: None, settings=None, dry_run=True)
    assert out["promoted"] is False and out["dry_run"] is True
    assert out["change_set"][0]["to_image"] == "nginx:1.29"
    assert called["deploy"] == 0                        # dry-run never deploys


@pytest.mark.asyncio
async def test_promote_rolls_back_whole_set_on_failure(monkeypatch):
    async def green(*a, **k):
        return {"passed": True}
    async def fake_inspect(agent, cf, s):
        return {"containers": [
            {"name": "web", "image": "nginx:1.27", "ports": [], "env": {}, "volumes": [], "restart": "no"},
            {"name": "db", "image": "pg:15", "ports": [], "env": {}, "volumes": [], "restart": "no"},
        ]}
    calls = []
    async def fake_deploy(agent, cf, s, *, name, image, **k):
        calls.append((name, image))
        ok = not (name == "db" and image == "pg:BROKEN")   # db's new image fails
        return {"ok": ok, "stderr": "boom" if not ok else ""}

    monkeypatch.setattr(system_promote, "rehearse", green)
    monkeypatch.setattr(system_promote, "inspect_containers", fake_inspect)
    monkeypatch.setattr(system_promote, "deploy_container", fake_deploy)

    sys = _system("web", "db")
    out = await system_promote.promote(sys, types.SimpleNamespace(id="t", name="prod"),
                                       {"web": "nginx:1.29", "db": "pg:BROKEN"}, lambda a, s: None, settings=None)
    assert out["promoted"] is False and out["failed_member"] == "db"
    assert out["rolled_back"] == ["web"]                # web (already applied) rolled back
    # web was deployed to new image, then rolled back to its original
    assert ("web", "nginx:1.29") in calls and ("web", "nginx:1.27") in calls
