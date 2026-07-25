"""Tests for System clone (Block 2) — the exported seed-host spec is transformed
for a disposable sandbox (docker names prefixed, host ports dropped) and
materialized, dry-run by default."""
from __future__ import annotations

import types

import pytest

from bossman.services import system_clone
from bossman.services.system_clone import _sandbox_prefix, _transform_for_sandbox


def test_sandbox_prefix_slugifies():
    assert _sandbox_prefix("demo-system") == "sbx-demo-system"
    assert _sandbox_prefix("Shop PROD!") == "sbx-shop-prod"
    assert _sandbox_prefix("") == "sbx-system"


def test_transform_prefixes_docker_and_drops_ports():
    spec = {"resources": [
        {"type": "config", "path": "/etc/app.conf", "values": {"a": "1"}},
        {"type": "docker_container", "name": "web", "image": "nginx",
         "ports": [{"host": "8080", "container": "80"}], "env": {"X": "1"}},
    ]}
    out = _transform_for_sandbox(spec, "sbx-demo")
    assert out["sandbox_prefix"] == "sbx-demo"
    cfg = [r for r in out["resources"] if r["type"] == "config"][0]
    dock = [r for r in out["resources"] if r["type"] == "docker_container"][0]
    assert cfg["path"] == "/etc/app.conf"        # config untouched
    assert dock["name"] == "sbx-demo-web"        # docker name prefixed
    assert dock["ports"] == []                   # host ports dropped
    assert dock["image"] == "nginx" and dock["env"] == {"X": "1"}  # rest preserved


@pytest.mark.asyncio
async def test_clone_system_exports_seed_transforms_and_materializes(monkeypatch):
    system = types.SimpleNamespace(id="s1", name="demo-system", seed_agent_id="seed1")
    target = types.SimpleNamespace(id="t1", name="staging")
    seed = types.SimpleNamespace(id="seed1", name="prod")

    async def fake_get(model, pk):
        return seed  # session.get(Agent, seed_agent_id)

    async def fake_export(session, agent, cf, s):
        assert agent is seed
        return {"resource_count": 2, "resources": [
            {"type": "config", "path": "/etc/app.conf", "values": {"a": "1"}},
            {"type": "docker_container", "name": "web", "image": "nginx",
             "ports": [{"host": "8080", "container": "80"}]},
        ]}

    captured = {}

    async def fake_materialize(session, target_agent, cf, s, spec, dry_run):
        captured["spec"] = spec
        captured["dry_run"] = dry_run
        return {"changed_count": 0, "docker": [{"name": "sbx-demo-system-web", "command": "docker run ..."}]}

    session = types.SimpleNamespace(get=fake_get)
    monkeypatch.setattr(system_clone, "export_server_spec", fake_export)
    monkeypatch.setattr(system_clone, "materialize_spec", fake_materialize)

    out = await system_clone.clone_system(session, system, target, lambda a, s: None, settings=None, dry_run=True)

    assert out["sandbox_prefix"] == "sbx-demo-system"
    assert out["seed"]["name"] == "prod" and out["target"]["name"] == "staging"
    assert captured["dry_run"] is True
    # the materialized spec is the sandbox-transformed one
    dock = [r for r in captured["spec"]["resources"] if r["type"] == "docker_container"][0]
    assert dock["name"] == "sbx-demo-system-web" and dock["ports"] == []


@pytest.mark.asyncio
async def test_clone_system_no_seed():
    system = types.SimpleNamespace(id="s1", name="x", seed_agent_id=None)
    target = types.SimpleNamespace(id="t1", name="staging")
    session = types.SimpleNamespace(get=None)
    out = await system_clone.clone_system(session, system, target, lambda a, s: None, settings=None)
    assert "error" in out
