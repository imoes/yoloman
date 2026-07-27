"""Tests for HelmReleaseResource — the k8s tier behind the Resource contract:
observe (helm list + get values), plan (diff chart/values), apply (helm upgrade
--install + generation), rollback (re-apply an earlier spec)."""
from __future__ import annotations

import types

import pytest

from bossman.services.resources import base, helm_release
from bossman.services.resources.helm_release import HelmReleaseResource


def _res(monkeypatch, releases, values, gen_store, install_ok=True):
    agent = types.SimpleNamespace(id="a1", name="docker-test")
    r = HelmReleaseResource(session=object(), agent=agent, client_factory=lambda a, s: None,
                            settings=None, name="web", namespace="bm")

    async def fake_list(a, cf, s):
        return {"releases": releases}

    async def fake_install(a, cf, s, *, name, chart, values_yaml, namespace, create_namespace):
        return {"ok": install_ok, "error": None if install_ok else "boom"}

    async def fake_values(self):  # bound-style override of _live_values
        return values

    async def fake_record(session, key, rtype, spec, *, note=None, applied_by=None):
        g = max((x["generation"] for x in gen_store), default=0) + 1
        gen_store.append({"generation": g, "spec": spec, "note": note})
        return g

    async def fake_getspec(session, key, generation):
        for x in gen_store:
            if x["generation"] == generation:
                return x["spec"]
        return None

    monkeypatch.setattr(helm_release.helm_app, "list_releases", fake_list)
    monkeypatch.setattr(helm_release.helm_app, "install_release", fake_install)
    monkeypatch.setattr(HelmReleaseResource, "_live_values", fake_values)
    monkeypatch.setattr(HelmReleaseResource, "_all_values", fake_values)   # observe() consults it too
    monkeypatch.setattr(base, "record_generation", fake_record)
    monkeypatch.setattr(base, "list_generations", lambda s, k: _sorted(gen_store))
    monkeypatch.setattr(base, "get_generation_spec", fake_getspec)
    return r


async def _sorted(store):  # helper coroutine for list_generations stub
    return list(reversed(store))


@pytest.mark.asyncio
async def test_observe_present_with_values(monkeypatch):
    r = _res(monkeypatch, [{"name": "web", "namespace": "bm", "chart": "nginx-1.0", "status": "deployed", "revision": 3}],
             {"replicaCount": 2}, [])
    obs = await r.observe()
    assert obs["chart"] == "nginx-1.0" and obs["revision"] == 3 and obs["values"] == {"replicaCount": 2}


@pytest.mark.asyncio
async def test_observe_absent(monkeypatch):
    r = _res(monkeypatch, [], {}, [])
    assert await r.observe() is None


@pytest.mark.asyncio
async def test_plan_update_on_values_change(monkeypatch):
    r = _res(monkeypatch, [{"name": "web", "namespace": "bm", "chart": "nginx-1.0", "status": "deployed", "revision": 1}],
             {"replicaCount": 1}, [])
    p = await r.plan({"chart": "nginx-1.0", "values": {"replicaCount": 3}})
    assert p["action"] == "update" and "values" in p["changed"]


@pytest.mark.asyncio
async def test_apply_records_generation(monkeypatch):
    store: list = []
    r = _res(monkeypatch, [], {}, store)
    out = await r.apply({"chart": "nginx-1.0", "values": {"replicaCount": 2}}, dry_run=False)
    assert out["ok"] and out["generation"] == 1 and store[0]["spec"]["chart"] == "nginx-1.0"


@pytest.mark.asyncio
async def test_apply_dry_run_no_record(monkeypatch):
    store: list = []
    r = _res(monkeypatch, [], {}, store)
    out = await r.apply({"chart": "nginx-1.0", "values": {}}, dry_run=True)
    assert out["dry_run"] is True and store == []


@pytest.mark.asyncio
async def test_rollback_reapplies_spec(monkeypatch):
    store = [{"generation": 1, "spec": {"name": "web", "namespace": "bm", "chart": "nginx-1.0", "values": {"replicaCount": 1}}, "note": None},
             {"generation": 2, "spec": {"name": "web", "namespace": "bm", "chart": "nginx-1.0", "values": {"replicaCount": 5}}, "note": None}]
    r = _res(monkeypatch, [{"name": "web", "namespace": "bm", "chart": "nginx-1.0", "status": "deployed", "revision": 2}],
             {"replicaCount": 5}, store)
    out = await r.rollback(1)
    assert out["ok"] and out["generation"] == 3 and store[-1]["note"] == "rollback to gen 1"
    assert store[-1]["spec"]["values"] == {"replicaCount": 1}


# --- values broken out (one typed field per value, not a JSON blob) -----------

def _res_with_all_values(monkeypatch, allv, gen_store=None):
    """A release whose `helm get values -a` returns `allv`."""
    r = _res(monkeypatch, [{"name": "web", "namespace": "bm", "chart": "nginx-1.0",
                            "status": "deployed", "revision": 1}], {}, gen_store or [])

    async def fake_all(self):
        return allv

    monkeypatch.setattr(HelmReleaseResource, "_all_values", fake_all)
    return r


@pytest.mark.asyncio
async def test_schema_breaks_out_every_value(monkeypatch):
    r = _res_with_all_values(monkeypatch, {
        "replicaCount": 2,
        "image": {"repository": "nginx", "tag": "1.27"},
        "ingress": {"enabled": False},
    })
    schema = await r.schema_async()
    assert set(schema) == {"replicaCount", "image.repository", "image.tag", "ingress.enabled"}
    assert "values" not in schema                       # no JSON blob
    assert schema["replicaCount"]["type"] == "number"
    assert schema["ingress.enabled"]["type"] == "bool"
    assert schema["image.repository"]["default"] == "nginx"


@pytest.mark.asyncio
async def test_observe_exposes_flat_values(monkeypatch):
    r = _res_with_all_values(monkeypatch, {"image": {"tag": "1.27"}})
    obs = await r.observe()
    assert obs["flat_values"] == {"image.tag": "1.27"}
    assert obs["all_values"] == {"image": {"tag": "1.27"}}


@pytest.mark.asyncio
async def test_apply_inflates_flat_values_exactly(monkeypatch):
    """A value key may itself contain dots (annotations!) — the index must restore
    the original nesting rather than splitting the string."""
    allv = {"ingress": {"annotations": {"kubernetes.io/ingress.class": "nginx"}}}
    captured = {}

    async def fake_install(a, cf, s, *, name, chart, values_yaml, namespace, create_namespace):
        captured["yaml"] = values_yaml
        return {"ok": True, "error": None}

    r = _res_with_all_values(monkeypatch, allv)
    monkeypatch.setattr(helm_release.helm_app, "install_release", fake_install)
    await r.observe()                       # builds the index
    await r.apply({"chart": "nginx", "values": {"ingress.annotations.kubernetes.io/ingress.class": "traefik"}},
                  dry_run=False)
    import yaml as _y
    assert _y.safe_load(captured["yaml"]) == {
        "ingress": {"annotations": {"kubernetes.io/ingress.class": "traefik"}}}
