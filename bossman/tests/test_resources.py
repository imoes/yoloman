"""Tests for the Resource/Deployable spine + DockerContainerResource — the
four-verb contract (observe/plan/apply/rollback) with DB-backed generations."""
from __future__ import annotations

import types

import pytest

from bossman.services.resources import base
from bossman.services.resources.docker_container import DockerContainerResource


def test_diff_specs_create_update_noop():
    fields = ["image", "ports"]
    assert base.diff_specs(None, {"image": "nginx"}, fields)["action"] == "create"
    upd = base.diff_specs({"image": "nginx:1", "ports": []}, {"image": "nginx:2", "ports": []}, fields)
    assert upd["action"] == "update" and upd["changed"] == {"image": ["nginx:1", "nginx:2"]}
    noop = base.diff_specs({"image": "nginx:1"}, {"image": "nginx:1"}, fields)
    assert noop["action"] == "noop" and noop["changed_count"] == 0


def _resource(monkeypatch, observed, gen_store):
    """A DockerContainerResource with docker + generation store faked in memory."""
    agent = types.SimpleNamespace(id="a1", name="docker-test")

    class _Session:
        """Answers only what these tests reach: `scalar`, used by base.no_such_generation to find
        the oldest generation still held so a PRUNED target reads differently from one that never
        existed. Backed by the same in-memory store as the rest of this harness."""
        async def scalar(self, _stmt):
            return min((g["generation"] for g in gen_store), default=None)

    r = DockerContainerResource(session=_Session(), agent=agent, client_factory=lambda a, s: None,
                                settings=None, name="web")

    async def fake_inspect(a, cf, s):
        return {"containers": ([observed] if observed else [])}

    async def fake_deploy(a, cf, s, *, name, image, ports, env, volumes, restart, dry_run):
        return {"ok": True, "container": name}

    async def fake_record(session, key, rtype, spec, *, note=None, applied_by=None):
        gen = (max((g["generation"] for g in gen_store), default=0) + 1)
        gen_store.append({"generation": gen, "spec": spec, "note": note})
        return gen

    async def fake_list(session, key):
        return list(reversed(gen_store))

    async def fake_get(session, key, generation):
        for g in gen_store:
            if g["generation"] == generation:
                return g["spec"]
        return None

    monkeypatch.setattr("bossman.services.resources.docker_container.inspect_containers", fake_inspect)
    monkeypatch.setattr("bossman.services.resources.docker_container.deploy_container", fake_deploy)
    monkeypatch.setattr(base, "record_generation", fake_record)
    monkeypatch.setattr(base, "list_generations", fake_list)
    monkeypatch.setattr(base, "get_generation_spec", fake_get)
    return r


@pytest.mark.asyncio
async def test_observe_and_plan(monkeypatch):
    observed = {"name": "web", "image": "nginx:1.27", "ports": [], "env": {}, "volumes": [], "restart": "unless-stopped"}
    r = _resource(monkeypatch, observed, [])
    assert (await r.observe())["image"] == "nginx:1.27"
    plan = await r.plan({"image": "nginx:1.29", "ports": [], "env": {}, "volumes": [], "restart": "unless-stopped"})
    assert plan["action"] == "update" and plan["changed"]["image"] == ["nginx:1.27", "nginx:1.29"]
    assert plan["resource_key"] == "docker:a1:web"


@pytest.mark.asyncio
async def test_apply_dry_run_does_not_record(monkeypatch):
    store: list = []
    r = _resource(monkeypatch, None, store)
    out = await r.apply({"image": "nginx:1.29"}, dry_run=True)
    assert out["dry_run"] is True and "generation" not in out and store == []


@pytest.mark.asyncio
async def test_apply_records_generation(monkeypatch):
    store: list = []
    r = _resource(monkeypatch, None, store)
    out = await r.apply({"image": "nginx:1.29", "ports": [], "env": {}, "volumes": [], "restart": "unless-stopped"},
                        dry_run=False)
    assert out["ok"] is True and out["generation"] == 1
    assert store[0]["spec"]["image"] == "nginx:1.29"


@pytest.mark.asyncio
async def test_rollback_reapplies_old_spec_as_new_generation(monkeypatch):
    # gen 1 = nginx:1.27, gen 2 = nginx:1.29; rollback to 1 → gen 3 with 1.27
    store = [{"generation": 1, "spec": {"name": "web", "image": "nginx:1.27", "ports": [], "env": {}, "volumes": [], "restart": "unless-stopped"}, "note": None},
             {"generation": 2, "spec": {"name": "web", "image": "nginx:1.29", "ports": [], "env": {}, "volumes": [], "restart": "unless-stopped"}, "note": None}]
    r = _resource(monkeypatch, store[1]["spec"], store)
    out = await r.rollback(1)
    assert out["ok"] is True and out["generation"] == 3
    assert store[-1]["spec"]["image"] == "nginx:1.27" and store[-1]["note"] == "rollback to gen 1"


@pytest.mark.asyncio
async def test_rollback_missing_generation(monkeypatch):
    """Nothing stored at all: the answer is "no generation", not "pruned"."""
    r = _resource(monkeypatch, None, [])
    out = await r.rollback(9)
    assert out["ok"] is False and "no generation 9" in out["error"]
    assert "pruned" not in out["error"]


@pytest.mark.asyncio
async def test_rollback_to_a_pruned_generation_says_pruned(monkeypatch):
    """A generation BELOW the oldest one still held was dropped to make room, and saying "no such
    generation" for it would make a trimmed history look like a typo."""
    r = _resource(monkeypatch, None, [{"generation": 7, "spec": {}, "note": None},
                                      {"generation": 8, "spec": {}, "note": None}])
    out = await r.rollback(3)
    assert out["ok"] is False
    assert "pruned" in out["error"] and "oldest still held is 7" in out["error"]
