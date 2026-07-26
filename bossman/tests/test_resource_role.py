"""Tests for RoleResource with BIND semantics.

A role is an OrchestrationPlan(plan_type="role") = the class; an
OrchestrationPlanLink(scope + parameters) = the instance. So the verbs are about
the BINDING, and `apply()` declares intent (creates the link + compiles the host's
desired state) instead of executing steps ad hoc — which `runbook/run` refuses on
purpose. The approval gate must be respected, not bypassed.
"""
from __future__ import annotations

import types
import uuid

import pytest

from bossman.services.resources import base, role as role_mod
from bossman.services.resources.role import RoleResource, _params_of

PLAN_ID = uuid.uuid4()
TENANT = uuid.uuid4()
AGENT_ID = uuid.uuid4()


def _plan(current_version: int = 2, enabled: bool = True):
    return types.SimpleNamespace(id=PLAN_ID, tenant_id=TENANT, name="web-base",
                                 plan_type="role", current_version=current_version,
                                 enabled=enabled, deleted_at=None)


def _version(schema=None, defaults=None):
    return types.SimpleNamespace(plan_id=PLAN_ID, version=2,
                                 parameter_schema=schema or {},
                                 default_parameters=defaults or {})


class _FakeSession:
    """Records adds/commits; scalars() is driven by the resource's queries in order."""

    def __init__(self, links=None):
        self.added: list = []
        self.deleted: list = []
        self.commits = 0
        self.links = links or []

    async def commit(self):
        self.commits += 1

    def add(self, obj):
        self.added.append(obj)

    async def delete(self, obj):
        self.deleted.append(obj)


def _res(monkeypatch, *, plan=None, version=None, assignments=(), links=(),
         yolo=False, preview=None, gen_store=None):
    session = _FakeSession(list(links))
    agent = types.SimpleNamespace(id=AGENT_ID, name="docker-test", tenant_id=TENANT, ou_id=None)
    r = RoleResource(session, agent, client_factory=lambda a, s: None, settings=None, name="web-base")

    async def fake_plan_row(self):
        self._plan = plan
        return plan

    async def fake_version_row(self):
        return version

    async def fake_assignments(sess, ag, extra=None):
        return list(assignments)

    async def fake_preview(*a, **k):
        return preview or {"affected_hosts": 1, "monitoring_diff": {}}

    async def fake_yolo(sess):
        return yolo

    compiled = {"called": 0}

    async def fake_compile(sess, agent_id):
        compiled["called"] += 1
        return types.SimpleNamespace(generation=11)

    store = gen_store if gen_store is not None else []

    async def fake_record(sess, key, rtype, spec, *, note=None, applied_by=None):
        g = max((x["generation"] for x in store), default=0) + 1
        store.append({"generation": g, "spec": spec, "note": note})
        return g

    async def fake_getspec(sess, key, generation):
        for x in store:
            if x["generation"] == generation:
                return x["spec"]
        return None

    monkeypatch.setattr(RoleResource, "_plan_row", fake_plan_row)
    monkeypatch.setattr(RoleResource, "_version_row", fake_version_row)
    monkeypatch.setattr(role_mod, "resolve_orchestration_assignments", fake_assignments)
    monkeypatch.setattr(role_mod, "preview_plan_link", fake_preview)
    monkeypatch.setattr(role_mod, "is_yolo_mode", fake_yolo)
    monkeypatch.setattr(role_mod, "compile_host_desired_state", fake_compile)
    monkeypatch.setattr(base, "record_generation", fake_record)
    monkeypatch.setattr(base, "get_generation_spec", fake_getspec)
    # the resource's link queries go through `await session.scalars(...)` → serve `links`
    async def scalars(stmt):  # noqa: ARG001
        return types.SimpleNamespace(
            first=lambda: (session.links[0] if session.links else None),
            all=lambda: list(session.links),
        )

    session.scalars = scalars
    return r, session, store, compiled


def _link(status="active", params=None):
    return types.SimpleNamespace(id=uuid.uuid4(), plan_id=PLAN_ID, agent_id=AGENT_ID,
                                 status=status, parameters=params or {}, priority=100,
                                 plan_version=2)


# ------------------------------------------------------------------- schema ----

def test_params_of_accepts_both_shapes():
    assert _params_of({"parameters": {"a": 1}}) == {"a": 1}
    assert _params_of({"a": 1, "require_approval": True}) == {"a": 1}   # control keys stripped


@pytest.mark.asyncio
async def test_schema_is_the_roles_parameter_schema(monkeypatch):
    r, *_ = _res(monkeypatch, plan=_plan(),
                 version=_version(schema={"domain": {"type": "string", "required": True}},
                                  defaults={"domain": "x.test"}))
    schema = await r.schema_async()
    assert schema["domain"]["required"] is True
    assert schema["domain"]["default"] == "x.test"     # default folded in from the version
    assert r.schema() == schema                        # sync half serves the cache


@pytest.mark.asyncio
async def test_schema_derived_from_defaults_when_unauthored(monkeypatch):
    r, *_ = _res(monkeypatch, plan=_plan(), version=_version(defaults={"port": 8080, "tls": True}))
    schema = await r.schema_async()
    assert schema["port"]["type"] == "number" and schema["tls"]["type"] == "bool"


@pytest.mark.asyncio
async def test_missing_role_observes_none(monkeypatch):
    r, *_ = _res(monkeypatch, plan=None, version=None)
    assert await r.observe() is None
    assert await r.schema_async() == {}


# ------------------------------------------------------------------ observe ----

@pytest.mark.asyncio
async def test_observe_reports_binding_and_its_source(monkeypatch):
    assignment = types.SimpleNamespace(plan_id=PLAN_ID, plan_name="web-base", plan_type="role",
                                       version=2, parameters={"domain": "x.test"},
                                       source="ou:/Germany/Prod")
    r, *_ = _res(monkeypatch, plan=_plan(), version=_version(), assignments=[assignment],
                 links=[_link()])
    obs = await r.observe()
    assert obs["bound"] is True and obs["source"] == "ou:/Germany/Prod"
    assert obs["parameters"] == {"domain": "x.test"}
    assert obs["host_links"][0]["status"] == "active"


@pytest.mark.asyncio
async def test_observe_unbound_role(monkeypatch):
    r, *_ = _res(monkeypatch, plan=_plan(), version=_version(), assignments=[], links=[])
    obs = await r.observe()
    assert obs["bound"] is False and obs["parameters"] == {} and obs["host_links"] == []


# --------------------------------------------------------------------- plan ----

@pytest.mark.asyncio
async def test_plan_uses_the_platform_preview_and_writes_nothing(monkeypatch):
    r, session, store, compiled = _res(monkeypatch, plan=_plan(), version=_version(),
                                       preview={"affected_hosts": 3})
    out = await r.plan({"parameters": {"domain": "x.test"}})
    assert out["action"] == "create" and out["preview"] == {"affected_hosts": 3}
    assert out["delegated_to"] == "orchestration.binding"
    assert session.added == [] and session.commits == 0 and compiled["called"] == 0
    assert store == []


@pytest.mark.asyncio
async def test_plan_is_noop_when_already_bound_with_same_parameters(monkeypatch):
    assignment = types.SimpleNamespace(plan_id=PLAN_ID, plan_name="web-base", plan_type="role",
                                       version=2, parameters={"domain": "x.test"}, source="host")
    r, *_ = _res(monkeypatch, plan=_plan(), version=_version(defaults={}),
                 assignments=[assignment], links=[_link(params={"domain": "x.test"})])
    out = await r.plan({"parameters": {"domain": "x.test"}})
    assert out["action"] == "noop" and out["changed_count"] == 0


# -------------------------------------------------------------------- apply ----

@pytest.mark.asyncio
async def test_apply_dry_run_only_plans(monkeypatch):
    r, session, store, compiled = _res(monkeypatch, plan=_plan(), version=_version())
    out = await r.apply({"parameters": {"domain": "x"}}, dry_run=True)
    assert out["dry_run"] is True and "plan" in out
    assert session.added == [] and compiled["called"] == 0 and store == []


@pytest.mark.asyncio
async def test_apply_creates_link_pending_approval_by_default(monkeypatch):
    """The governance gate: without YOLO and without waiving approval, the binding
    starts pending — and apply() says so instead of claiming success."""
    r, session, store, compiled = _res(monkeypatch, plan=_plan(), version=_version(), yolo=False)
    out = await r.apply({"parameters": {"domain": "x"}, "require_approval": True}, dry_run=False)
    assert out["ok"] is True and out["status"] == "pending_approval"
    assert out["awaiting_approval"] is True
    assert compiled["called"] == 0            # nothing converges before approval
    assert len(session.added) == 1 and session.added[0].target_type == "host"
    assert store[0]["spec"]["parameters"] == {"domain": "x"}


@pytest.mark.asyncio
async def test_apply_activates_under_yolo_and_compiles(monkeypatch):
    r, session, store, compiled = _res(monkeypatch, plan=_plan(), version=_version(), yolo=True)
    out = await r.apply({"parameters": {"domain": "x"}}, dry_run=False)
    assert out["status"] == "active" and out["awaiting_approval"] is False
    assert compiled["called"] == 1 and out["compiled_generation"] == 11
    assert out["generation"] == 1


@pytest.mark.asyncio
async def test_apply_waived_approval_activates(monkeypatch):
    r, _s, _st, compiled = _res(monkeypatch, plan=_plan(), version=_version(), yolo=False)
    out = await r.apply({"parameters": {}, "require_approval": False}, dry_run=False)
    assert out["status"] == "active" and compiled["called"] == 1


@pytest.mark.asyncio
async def test_apply_updates_existing_link_instead_of_stacking(monkeypatch):
    existing = _link(status="active", params={"domain": "old"})
    r, session, *_ = _res(monkeypatch, plan=_plan(), version=_version(), yolo=True,
                          links=[existing])
    await r.apply({"parameters": {"domain": "new"}}, dry_run=False)
    assert session.added == []                      # no second link
    assert existing.parameters == {"domain": "new"}


@pytest.mark.asyncio
async def test_apply_unknown_role_fails_cleanly(monkeypatch):
    r, *_ = _res(monkeypatch, plan=None, version=None)
    out = await r.apply({"parameters": {}}, dry_run=False)
    assert out["ok"] is False and "no such role" in out["error"]


# ----------------------------------------------------------------- rollback ----

@pytest.mark.asyncio
async def test_rollback_rebinds_earlier_parameters_with_caveat(monkeypatch):
    store = [{"generation": 1, "spec": {"name": "web-base", "parameters": {"domain": "a"}}, "note": None},
             {"generation": 2, "spec": {"name": "web-base", "parameters": {"domain": "b"}}, "note": None}]
    existing = _link(params={"domain": "b"})
    r, _s, st, _c = _res(monkeypatch, plan=_plan(), version=_version(), yolo=True,
                         links=[existing], gen_store=store)
    out = await r.rollback(1)
    assert out["ok"] is True and existing.parameters == {"domain": "a"}
    assert "re-bound" in out["caveat"]
    assert st[-1]["note"] == "rollback to gen 1"


@pytest.mark.asyncio
async def test_rollback_missing_generation(monkeypatch):
    r, *_ = _res(monkeypatch, plan=_plan(), version=_version())
    out = await r.rollback(9)
    assert out["ok"] is False and "no generation 9" in out["error"]


# ------------------------------------------------------------------- unbind ----

@pytest.mark.asyncio
async def test_unbind_removes_host_link_and_recompiles(monkeypatch):
    r, session, _st, compiled = _res(monkeypatch, plan=_plan(), version=_version(),
                                     links=[_link()])
    out = await r.unbind()
    assert out["ok"] is True and out["unbound"] == 1
    assert len(session.deleted) == 1 and compiled["called"] == 1


@pytest.mark.asyncio
async def test_schema_uses_compiled_roles_param_specs_as_the_schema(monkeypatch):
    """nt_compile.role_to_plan_input stores a role's `parameters:` BLOCK (specs, not
    values) in default_parameters — treating those as values produced nonsense
    object fields, so detect the spec shape and use it as the schema."""
    specs = {"timezone": {"type": "string", "default": "Europe/Berlin", "required": False},
             "ssh_port": {"type": "number", "default": "22", "required": False}}
    r, *_ = _res(monkeypatch, plan=_plan(), version=_version(defaults=specs))
    schema = await r.schema_async()
    assert schema["timezone"]["type"] == "string"      # not "object"
    assert schema["timezone"]["default"] == "Europe/Berlin"
    assert schema["ssh_port"]["type"] == "number"
