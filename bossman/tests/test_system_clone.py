"""Tests for System clone (Block 2) — the exported seed-host spec is transformed
for a disposable sandbox (docker names prefixed, host ports dropped) and
materialized, dry-run by default."""
from __future__ import annotations

import types

import pytest

from bossman.services import system_clone
from bossman.services.system_clone import (
    _inject_sandbox_secrets,
    _is_secret_key,
    _redact,
    _sandbox_prefix,
    _transform_for_sandbox,
)


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


def test_is_secret_key():
    for k in ("PASSWORD", "db_pass", "API_KEY", "apikey", "SECRET_TOKEN", "private_key", "credential"):
        assert _is_secret_key(k), k
    for k in ("host", "port", "image", "replicas", "name"):
        assert not _is_secret_key(k), k


def test_inject_sandbox_secrets_docker_env_only():
    spec = {"resources": [
        {"type": "docker_container", "name": "db", "env": {"POSTGRES_PASSWORD": "prod-secret", "PGHOST": "db"}},
        # config values are NOT scanned — a directive named "passwd" is not a secret
        {"type": "config", "path": "/etc/nsswitch.conf", "values": {"passwd": "files systemd", "port": "80"}},
    ]}
    out, refs, fresh = _inject_sandbox_secrets(spec, settings=None)
    env = out["resources"][0]["env"]
    vals = out["resources"][1]["values"]
    # docker secret replaced with a fresh one; non-secret env untouched
    assert env["POSTGRES_PASSWORD"] != "prod-secret" and env["PGHOST"] == "db"
    # config left completely untouched (no false-positive corruption)
    assert vals == {"passwd": "files systemd", "port": "80"}
    keys = {r["key"] for r in refs}
    assert keys == {"POSTGRES_PASSWORD"}
    assert "prod-secret" not in fresh and env["POSTGRES_PASSWORD"] in fresh


def test_redact_masks_fresh_secrets():
    fresh = {"abc123", "xyz789"}
    result = {"docker": [{"command": "docker run -e PW=abc123 img"}], "note": "xyz789 here"}
    red = _redact(result, fresh)
    assert red["docker"][0]["command"] == "docker run -e PW=*** img"
    assert red["note"] == "*** here"


@pytest.mark.asyncio
async def test_clone_system_member_scoped_from_live_inspect(monkeypatch):
    # a system with ONE docker member "web"; the seed host also runs "other"
    system = types.SimpleNamespace(id="s1", name="demo-system", seed_agent_id="seed1",
                                   members=[types.SimpleNamespace(target="docker", app="web", config={})])
    target = types.SimpleNamespace(id="t1", name="staging")
    seed = types.SimpleNamespace(id="seed1", name="prod")

    async def fake_get(model, pk):
        return seed  # session.get(Agent, seed_agent_id)

    async def fake_inspect(agent, cf, s):
        assert agent is seed  # inspect the SEED, live
        return {"containers": [
            {"name": "web", "image": "nginx:1.27", "ports": [{"host": "8080", "container": "80"}],
             "env": {"X": "1"}, "volumes": ["/d:/d"], "restart": "unless-stopped"},
            {"name": "other", "image": "redis"},   # NOT a member → excluded
        ]}

    captured = {}

    async def fake_materialize(session, target_agent, cf, s, spec, dry_run):
        captured["spec"] = spec
        captured["dry_run"] = dry_run
        return {"changed_count": 0, "docker": [{"name": "sbx-demo-system-web", "command": "docker run ..."}]}

    session = types.SimpleNamespace(get=fake_get)
    monkeypatch.setattr(system_clone, "inspect_containers", fake_inspect)
    monkeypatch.setattr(system_clone, "materialize_spec", fake_materialize)

    out = await system_clone.clone_system(session, system, target, lambda a, s: None, settings=None, dry_run=True)

    assert out["sandbox_prefix"] == "sbx-demo-system" and out["member_count"] == 1
    assert out["seed"]["name"] == "prod" and out["target"]["name"] == "staging"
    # only the member "web" is cloned; "other" is excluded (member-scoped)
    names = [r["name"] for r in captured["spec"]["resources"]]
    assert names == ["sbx-demo-system-web"]
    dock = captured["spec"]["resources"][0]
    assert dock["ports"] == [] and dock["image"] == "nginx:1.27" and dock["volumes"] == ["/d:/d"]


@pytest.mark.asyncio
async def test_clone_system_no_seed():
    system = types.SimpleNamespace(id="s1", name="x", seed_agent_id=None, members=[])
    target = types.SimpleNamespace(id="t1", name="staging")
    session = types.SimpleNamespace(get=None)
    out = await system_clone.clone_system(session, system, target, lambda a, s: None, settings=None)
    assert "error" in out


@pytest.mark.asyncio
async def test_clone_system_no_docker_members():
    system = types.SimpleNamespace(id="s1", name="x", seed_agent_id="seed1",
                                   members=[types.SimpleNamespace(target="native", app="nginx", config={})])
    seed = types.SimpleNamespace(id="seed1", name="prod")

    async def fake_get(model, pk):
        return seed
    out = await system_clone.clone_system(types.SimpleNamespace(get=fake_get), system,
                                          types.SimpleNamespace(id="t", name="staging"),
                                          lambda a, s: None, settings=None)
    assert "error" in out and "no docker members" in out["error"]
