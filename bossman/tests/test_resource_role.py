"""Tests for RoleResource — a runbook Role as a Resource: parameters are the
constructor (schema), plan = a check-mode run, apply = a real run that records the
applied PARAMETER SET as the rollback point (the engine's run audit doesn't keep
params), rollback = re-run with an earlier set (forward-converge, caveat stated)."""
from __future__ import annotations

import types

import pytest

from bossman.services.resources import base, role as role_mod
from bossman.services.resources.role import RoleResource

ROLE_DOC = {
    "kind": "role", "name": "web-base",
    "parameters": {"port": {"type": "number", "default": 80}, "domain": {"type": "string", "required": True}},
    "steps": [{"name": "install", "module": "package", "args": {"name": "nginx"}}],
}


def _res(monkeypatch, gen_store, run_result):
    agent = types.SimpleNamespace(id="a1", name="docker-test")
    r = RoleResource(session=object(), agent=agent, client_factory=lambda a, s: None,
                     settings=None, name="web-base")

    async def fake_doc(self):
        self._doc = ROLE_DOC
        return ROLE_DOC

    captured: dict = {}

    async def fake_run(self, params, dry_run):
        captured["params"] = params
        captured["dry_run"] = dry_run
        return run_result

    async def fake_record(session, key, rtype, spec, *, note=None, applied_by=None):
        g = max((x["generation"] for x in gen_store), default=0) + 1
        gen_store.append({"generation": g, "spec": spec, "note": note})
        return g

    async def fake_getspec(session, key, generation):
        for x in gen_store:
            if x["generation"] == generation:
                return x["spec"]
        return None

    monkeypatch.setattr(RoleResource, "_role_doc", fake_doc)
    monkeypatch.setattr(RoleResource, "_run", fake_run)
    monkeypatch.setattr(base, "record_generation", fake_record)
    monkeypatch.setattr(base, "get_generation_spec", fake_getspec)
    return r, captured


@pytest.mark.asyncio
async def test_schema_is_the_roles_parameters(monkeypatch):
    r, _ = _res(monkeypatch, [], {})
    assert await r.schema_async() == ROLE_DOC["parameters"]
    assert r.resource_key == "role:a1:web-base"


@pytest.mark.asyncio
async def test_plan_is_a_check_mode_run(monkeypatch):
    result = {"steps": [{"name": "install", "status": "changed", "changed": True},
                        {"name": "noop", "status": "ok", "changed": False}]}
    r, cap = _res(monkeypatch, [], result)
    p = await r.plan({"parameters": {"domain": "x.test"}})
    assert cap["dry_run"] is True and cap["params"] == {"domain": "x.test"}
    assert p["action"] == "update" and p["changed_count"] == 1 and p["steps_total"] == 2
    assert p["delegated_to"] == "runbook.engine"


@pytest.mark.asyncio
async def test_apply_records_parameter_set(monkeypatch):
    store: list = []
    r, cap = _res(monkeypatch, store, {"ok": True, "changed": True, "steps": [{"name": "install"}]})
    out = await r.apply({"parameters": {"domain": "x.test", "port": 8080}}, dry_run=False)
    assert out["ok"] and out["generation"] == 1 and cap["dry_run"] is False
    assert store[0]["spec"]["parameters"] == {"domain": "x.test", "port": 8080}


@pytest.mark.asyncio
async def test_apply_dry_run_returns_plan_without_recording(monkeypatch):
    store: list = []
    r, _ = _res(monkeypatch, store, {"steps": []})
    out = await r.apply({"parameters": {"domain": "x"}}, dry_run=True)
    assert out["dry_run"] is True and "plan" in out and store == []


@pytest.mark.asyncio
async def test_apply_failed_run_reports_and_records_nothing(monkeypatch):
    store: list = []
    r, _ = _res(monkeypatch, store, {"ok": False, "steps": [{"name": "install", "status": "failed"}]})
    out = await r.apply({"parameters": {}}, dry_run=False)
    assert out["ok"] is False and "error" in out and store == []


@pytest.mark.asyncio
async def test_rollback_reruns_earlier_params_with_caveat(monkeypatch):
    store = [{"generation": 1, "spec": {"name": "web-base", "parameters": {"port": 80}}, "note": None},
             {"generation": 2, "spec": {"name": "web-base", "parameters": {"port": 8080}}, "note": None}]
    r, cap = _res(monkeypatch, store, {"ok": True, "changed": True, "steps": []})
    out = await r.rollback(1)
    assert out["ok"] and cap["params"] == {"port": 80}
    assert "forward-converge" in out["caveat"]
    assert store[-1]["note"] == "rollback to gen 1"


@pytest.mark.asyncio
async def test_rollback_missing_generation(monkeypatch):
    r, _ = _res(monkeypatch, [], {})
    out = await r.rollback(9)
    assert out["ok"] is False and "no generation 9" in out["error"]
