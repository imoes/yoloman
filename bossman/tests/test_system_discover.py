"""Tests for System discovery — propose a System from a seed host's live state
(docker + k8s + native members) with compose-derived wiring, no persistence."""
from __future__ import annotations

import types

import pytest

from bossman.services import system_discover


@pytest.mark.asyncio
async def test_propose_system_spans_tiers_and_wires_compose(monkeypatch):
    agent = types.SimpleNamespace(id="a1", name="docker-test")

    async def fake_inspect(a, cf, s):
        return {"containers": [
            {"name": "shop-web", "image": "nginx", "compose_project": "shop", "compose_service": "web",
             "compose_file": "/srv/shop/dc.yml"},
            {"name": "shop-db", "image": "postgres", "compose_project": "shop", "compose_service": "db",
             "compose_file": "/srv/shop/dc.yml"},
            {"name": "solo", "image": "redis", "compose_project": None, "compose_service": None, "compose_file": None},
        ]}

    async def fake_releases(a, cf, s):
        return {"releases": [{"name": "cache", "chart": "redis-1.2.3"}]}

    async def fake_doc(session, a, cf, s, include):
        return {"config": {"observed": {"services": [{"name": "nginx.service"}, {"name": "sshd.service"}]}}}

    monkeypatch.setattr(system_discover, "inspect_containers", fake_inspect)
    monkeypatch.setattr(system_discover, "list_releases", fake_releases)
    monkeypatch.setattr(system_discover, "build_server_document", fake_doc)
    monkeypatch.setattr(system_discover, "_catalog_ids", lambda s: {"nginx", "postgresql"})  # sshd not a catalog app

    out = await system_discover.propose_system(None, agent, lambda a, s: None, settings=None)

    by_target = {}
    for m in out["members"]:
        by_target.setdefault(m["target"], []).append(m["app"])
    assert set(by_target["docker"]) == {"shop-web", "shop-db", "solo"}
    assert by_target["k8s"] == ["cache"]
    assert by_target["native"] == ["nginx"]              # sshd filtered (not in catalog)
    assert out["member_count"] == 5
    assert out["name"] == "docker-test-system"

    # compose wiring: shop-web ─▶ shop-db within project "shop"; solo has no edge
    assert out["edges"] == [{"from": "docker/shop-web", "to": "docker/shop-db", "kind": "compose:shop"}]


@pytest.mark.asyncio
async def test_propose_system_best_effort_when_sources_fail(monkeypatch):
    agent = types.SimpleNamespace(id="a1", name="bare")

    async def boom(*a, **k):
        raise RuntimeError("no docker")

    monkeypatch.setattr(system_discover, "inspect_containers", boom)
    monkeypatch.setattr(system_discover, "list_releases", boom)
    monkeypatch.setattr(system_discover, "build_server_document", boom)

    out = await system_discover.propose_system(None, agent, lambda a, s: None, settings=None)
    assert out["member_count"] == 0 and out["edges"] == []  # nothing discovered, no crash
