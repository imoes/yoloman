"""KubernetesObjectResource — the k8s tier behind the Resource contract, offline.

A fake access-host client answers `kubectl` module calls per verb and records them, so every assertion
is about what the resource SENDS (argv-shaping params, the manifest on stdin) and what it records
(generations, proposals), with no cluster. The live lifecycle is test_kubernetes_lifecycle_live.py.
"""
from __future__ import annotations

import json
import types
import uuid

import pytest

from bossman.services import resources as reg
from bossman.services.resources import base, kubernetes_object
from bossman.services.resources.kubernetes_object import KubernetesObjectResource

CM = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "web-config", "namespace": "demo", "uid": "u-1",
                                                           "resourceVersion": "10", "generation": 1},
      "data": {"LOG_LEVEL": "info"}}


class Fake:
    """`call_tool("kubectl", params)` → the module's envelope. `exists` controls get; `diff_rc` the diff."""

    def __init__(self, exists=True, diff_rc=1, dry_rc=0, dry_stderr="", apply_rc=0, owned=()):
        self.exists, self.diff_rc, self.dry_rc, self.dry_stderr, self.apply_rc, self.owned = exists, diff_rc, dry_rc, dry_stderr, apply_rc, list(owned)
        self.calls: list[dict] = []
        self._timeout = None

    def _env(self, rc, stdout="", stderr="", parsed=None):
        d = {"rc": rc, "stdout": stdout, "stderr": stderr}
        if parsed is not None:
            d["parsed"] = parsed
        return {"changed": rc == 0, "msg": "kubectl", "data": d}

    async def call_tool(self, name, body):
        assert name == "kubectl"
        self.calls.append(body)
        verb = body["verb"]
        if verb == "get" and body.get("name"):
            if not self.exists:
                return self._env(1, stderr='Error from server (NotFound): configmaps "web-config" not found')
            return self._env(0, json.dumps(CM), parsed=CM)
        if verb == "get":  # dependents query
            return self._env(0, "{}", parsed={"kind": "List", "items": self.owned})
        if verb == "apply-dry-run":
            if self.dry_rc:
                return self._env(self.dry_rc, stderr=self.dry_stderr or "error: admission webhook denied")
            return self._env(0, "{}", self.dry_stderr, parsed=json.loads(body["manifest"]))
        if verb == "diff":
            return self._env(self.diff_rc, "-  LOG_LEVEL: info\n+  LOG_LEVEL: debug\n" if self.diff_rc == 1 else "")
        if verb == "apply":
            if self.apply_rc:
                return self._env(self.apply_rc, stderr="error: conflict with field manager other")
            return self._env(0, "{}", "Warning: something deprecated", parsed=json.loads(body["manifest"]))
        if verb == "delete":
            return self._env(0, "{}", parsed={"kind": "ConfigMap"})
        return self._env(0, "{}", parsed={})


def _res(monkeypatch, fake, gen_store, *, yolo=True, proposals=None, kind="ConfigMap", api_version="v1"):
    agent = types.SimpleNamespace(id=uuid.uuid4(), name="hal", address="10.0.0.9:8010")
    cluster = types.SimpleNamespace(id=uuid.uuid4(), name="minikube", agent_id=agent.id, context=None, kubeconfig_path=None, inventory={})
    r = KubernetesObjectResource(session=object(), agent=agent, client_factory=lambda a, s: fake, settings=None,
                                 name="web-config", cluster=cluster, namespace="demo", api_version=api_version, kind=kind,
                                 requested_by="alice")

    async def fake_record(session, key, rtype, spec, *, note=None, applied_by=None):
        g = max((x["generation"] for x in gen_store), default=0) + 1
        gen_store.append({"generation": g, "spec": spec, "note": note, "applied_by": applied_by, "key": key, "type": rtype})
        return g

    async def fake_list(session, key):
        return list(reversed(gen_store))

    async def fake_getspec(session, key, generation):
        return next((x["spec"] for x in gen_store if x["generation"] == generation), None)

    async def fake_yolo(session):
        return yolo

    monkeypatch.setattr(base, "record_generation", fake_record)
    monkeypatch.setattr(base, "list_generations", fake_list)
    monkeypatch.setattr(base, "get_generation_spec", fake_getspec)
    monkeypatch.setattr(kubernetes_object, "is_yolo_mode", fake_yolo)
    if proposals is not None:
        from bossman.services import proposals as proposals_mod

        async def fake_create(session, agent, cluster, *, manifest, preview, requested_by, title="", delete=False):
            proposals.append({"manifest": manifest, "preview": preview, "requested_by": requested_by, "title": title,
                              "delete": delete})
            return types.SimpleNamespace(id=uuid.uuid4())

        monkeypatch.setattr(proposals_mod, "create_kubernetes_proposal", fake_create)
    return r


def _desired(level="debug"):
    return {"manifest": {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "web-config", "namespace": "demo"},
                         "data": {"LOG_LEVEL": level}}}


@pytest.mark.asyncio
async def test_observe_separates_spec_status_and_names_the_state(monkeypatch):
    fake = Fake()
    r = _res(monkeypatch, fake, [])
    obs = await r.observe()
    assert obs["kind"] == "ConfigMap" and obs["data_keys"] == ["LOG_LEVEL"]
    assert obs["state"]["state"] == "static"           # a ConfigMap has no runtime status, and says so
    assert obs["versions"]["resource_version"] == "10" and obs["etcd_key"] == "/registry/configmaps/demo/web-config"
    assert obs["manifest"]["data"] == {"LOG_LEVEL": "info"} and "status" not in obs["manifest"]
    get = fake.calls[0]
    assert get["verb"] == "get" and get["resource"] == "ConfigMap" and get["name"] == "web-config" and get["namespace"] == "demo"
    assert "--show-managed-fields" in get["args"]
    assert r.resource_key.startswith("k8s:") and r.resource_key.endswith(":demo:v1:ConfigMap:web-config")


@pytest.mark.asyncio
async def test_observe_none_when_absent_and_plan_says_create(monkeypatch):
    fake = Fake(exists=False)
    r = _res(monkeypatch, fake, [])
    assert await r.observe() is None
    plan = await r.plan(_desired())
    assert plan["action"] == "create" and plan["changed_count"] == 1 and plan["observed"] is None
    verbs = [c["verb"] for c in fake.calls]
    assert "apply-dry-run" in verbs and "diff" not in verbs   # nothing to diff against


@pytest.mark.asyncio
async def test_plan_update_runs_server_dry_run_then_diff(monkeypatch):
    fake = Fake(diff_rc=1, dry_stderr="Warning: v1 ConfigMap is fine")
    r = _res(monkeypatch, fake, [])
    plan = await r.plan(_desired())
    assert plan["action"] == "update" and "LOG_LEVEL: debug" in plan["diff_text"]
    assert plan["server_warnings"] == "Warning: v1 ConfigMap is fine"
    dry = next(c for c in fake.calls if c["verb"] == "apply-dry-run")
    assert json.loads(dry["manifest"])["data"] == {"LOG_LEVEL": "debug"} and dry["namespace"] == "demo"
    diff = next(c for c in fake.calls if c["verb"] == "diff")
    assert "--server-side" in diff["args"] and "--field-manager=bossman" in diff["args"]
    # identical → noop, nothing to change
    fake2 = Fake(diff_rc=0)
    r2 = _res(monkeypatch, fake2, [])
    assert (await r2.plan(_desired("info")))["action"] == "noop"


@pytest.mark.asyncio
async def test_plan_refused_by_the_server_is_the_preview(monkeypatch):
    fake = Fake(dry_rc=1, dry_stderr='Error from server (Forbidden): pods "x" is forbidden: violates PodSecurity "restricted:latest"')
    r = _res(monkeypatch, fake, [])
    plan = await r.plan(_desired())
    assert plan["action"] == "refused" and plan["refused"] and "PodSecurity" in plan["reason"]
    # and apply does not even try
    res = await r.apply(_desired(), dry_run=False)
    assert res["ok"] is False and "PodSecurity" in res["error"] and not any(c["verb"] == "apply" for c in fake.calls)


@pytest.mark.asyncio
async def test_manifest_naming_another_object_is_refused(monkeypatch):
    r = _res(monkeypatch, Fake(), [])
    with pytest.raises(ValueError) as e:
        await r.plan({"manifest": {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "other", "namespace": "demo"}}})
    assert "metadata.name" in str(e.value) and "other" in str(e.value)
    # a bare manifest (no "manifest" wrapper) with identity omitted is completed from the resource
    plan = await r.plan({"apiVersion": "v1", "kind": "ConfigMap", "data": {"A": "1"}})
    assert plan["desired"]["manifest"]["metadata"] == {"name": "web-config", "namespace": "demo"}


@pytest.mark.asyncio
async def test_flat_form_values_are_inflated_into_the_live_manifest(monkeypatch):
    """The generic inspector posts the keys schema_async() derived; they must land in the live manifest."""
    fake = Fake(diff_rc=1)
    r = _res(monkeypatch, fake, [])
    schema = await r.schema_async()
    assert "LOG_LEVEL" in schema or "data.LOG_LEVEL" in schema
    key = "data.LOG_LEVEL" if "data.LOG_LEVEL" in schema else "LOG_LEVEL"
    plan = await r.plan({key: "trace", "require_approval": True})
    assert plan["desired"]["manifest"]["data"] == {"LOG_LEVEL": "trace"}
    assert plan["desired"]["manifest"]["metadata"] == {"name": "web-config", "namespace": "demo"}
    r2 = _res(monkeypatch, Fake(exists=False), [])
    with pytest.raises(ValueError) as e:
        await r2.plan({"LOG_LEVEL": "x"})
    assert "does not exist" in str(e.value)


@pytest.mark.asyncio
async def test_apply_is_server_side_and_records_a_generation_under_yolo(monkeypatch):
    fake = Fake()
    gens: list = []
    r = _res(monkeypatch, fake, gens, yolo=True)
    assert (await r.apply(_desired(), dry_run=True))["dry_run"] is True and not any(c["verb"] == "apply" for c in fake.calls)
    res = await r.apply(_desired(), dry_run=False, note="bump log level")
    assert res["ok"] and res["applied"] and res["generation"] == 1 and res["awaiting_approval"] is False
    assert res["warnings"] == "Warning: something deprecated"
    ap = next(c for c in fake.calls if c["verb"] == "apply")
    assert json.loads(ap["manifest"])["metadata"]["name"] == "web-config"
    assert gens[0]["spec"]["manifest"]["data"] == {"LOG_LEVEL": "debug"} and gens[0]["applied_by"] == "alice" and gens[0]["type"] == "k8s_object"


@pytest.mark.asyncio
async def test_apply_outside_yolo_files_a_proposal_and_records_no_generation(monkeypatch):
    fake = Fake()
    gens: list = []
    filed: list = []
    r = _res(monkeypatch, fake, gens, yolo=False, proposals=filed)
    res = await r.apply(_desired(), dry_run=False)
    assert res["ok"] and res["applied"] is False and res["awaiting_approval"] and res["status"] == "pending_approval" and res["proposal_id"]
    assert not any(c["verb"] == "apply" for c in fake.calls)
    assert gens == []                                  # a never-applied generation would be a false rollback target
    assert filed[0]["manifest"]["data"] == {"LOG_LEVEL": "debug"} and filed[0]["preview"]["action"] == "update"
    assert filed[0]["requested_by"] == "alice" and "ConfigMap demo/web-config on minikube" == filed[0]["title"]
    await r.apply(_desired(), dry_run=False, note="rollback to gen 1")
    assert filed[1]["title"].endswith(" — rollback to gen 1")        # the origin survives into the proposal
    # the waiver (an approved proposal re-applies with it) goes straight through
    res = await r.apply({**_desired(), "require_approval": False}, dry_run=False)
    assert res["applied"] and gens[0]["generation"] == 1


@pytest.mark.asyncio
async def test_apply_failure_is_a_result_with_the_servers_reason(monkeypatch):
    fake = Fake(apply_rc=1)
    gens: list = []
    r = _res(monkeypatch, fake, gens)
    res = await r.apply(_desired(), dry_run=False)
    assert res["ok"] is False and "conflict with field manager" in res["error"] and gens == []


@pytest.mark.asyncio
async def test_rollback_reapplies_as_a_new_generation_and_names_a_pruned_one(monkeypatch):
    fake = Fake()
    gens: list = []
    r = _res(monkeypatch, fake, gens)
    await r.apply(_desired("info"), dry_run=False)
    await r.apply(_desired("debug"), dry_run=False)
    res = await r.rollback(1)
    assert res["ok"] and res["generation"] == 3
    assert gens[-1]["spec"]["manifest"]["data"] == {"LOG_LEVEL": "info"} and gens[-1]["note"] == "rollback to gen 1"
    assert (await r.generations())[0]["generation"] == 3

    async def no_such(session, key, generation, name):
        return {"ok": False, "error": f"no generation {generation} for {name}"}

    monkeypatch.setattr(base, "no_such_generation", no_such)
    assert (await r.rollback(99))["ok"] is False


@pytest.mark.asyncio
async def test_delete_previews_dependents_and_kept_pvcs_then_records_the_vanishing(monkeypatch):
    dep = {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "web-config", "namespace": "demo", "uid": "u-1"},
           "spec": {"template": {"spec": {"volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "web-data"}}]}}}}
    owned = [
        {"kind": "ReplicaSet", "metadata": {"name": "web-config-abc", "uid": "u-rs", "ownerReferences": [{"uid": "u-1"}]}},
        {"kind": "Pod", "metadata": {"name": "web-config-abc-xyz", "uid": "u-pod", "ownerReferences": [{"uid": "u-rs"}]}},
        {"kind": "Pod", "metadata": {"name": "unrelated", "uid": "u-x", "ownerReferences": [{"uid": "u-other"}]}},
    ]
    fake = Fake(owned=owned)
    # make `get <name>` answer the Deployment instead of the ConfigMap
    monkeypatch.setitem(CM, "kind", "Deployment"); CM["apiVersion"] = "apps/v1"; CM["spec"] = dep["spec"]
    try:
        gens: list = []
        r = _res(monkeypatch, fake, gens, kind="Deployment", api_version="apps/v1")
        pv = await r.delete(preview=True)
        assert pv["ok"] and pv["preview"]
        assert [d["name"] for d in pv["dependents"]] == ["web-config-abc", "web-config-abc-xyz"]
        assert pv["kept"][0]["name"] == "web-data" and "never deleted" in pv["kept"][0]["why"]
        assert not any(c["verb"] == "delete" for c in fake.calls)
        res = await r.delete(preview=False)
        assert res["deleted"] and res["generation"] == 1
        dl = next(c for c in fake.calls if c["verb"] == "delete")
        assert dl["resource"] == "Deployment.v1.apps" and dl["name"] == "web-config" and dl["namespace"] == "demo"
        assert gens[0]["spec"]["deleted"] is True and gens[0]["spec"]["manifest"]["kind"] == "Deployment"
    finally:
        CM["kind"], CM["apiVersion"] = "ConfigMap", "v1"
        CM.pop("spec", None)


# ---- the registry's build() branch --------------------------------------------------------------

class _Agent:
    def __init__(self):
        self.id, self.name, self.address = uuid.uuid4(), "hal", "10.0.0.9:8010"


class _Session:
    """Dispatches session.get on the model class, so the agent and the cluster lookups are separable."""

    def __init__(self, agent, cluster):
        self.agent, self.cluster = agent, cluster

    async def get(self, model, pk):
        from bossman.db.models import KubernetesCluster
        if model is KubernetesCluster:
            return self.cluster if (self.cluster is not None and pk == self.cluster.id) else None
        return self.agent


@pytest.mark.asyncio
async def test_build_checks_the_cluster_and_its_access_host():
    agent = _Agent()
    cluster = types.SimpleNamespace(id=uuid.uuid4(), name="mk", agent_id=agent.id, context=None, kubeconfig_path=None, inventory={})
    r = await reg.build("k8s", agent_id=agent.id, name="web", session=_Session(agent, cluster), settings=None,
                        client_factory=lambda a, s: None, identity=types.SimpleNamespace(name="bob"),
                        cluster=str(cluster.id), namespace="demo", api_version="apps/v1", object_kind="Deployment")
    assert isinstance(r, KubernetesObjectResource) and r.kind == "Deployment" and r.requested_by == "bob"
    with pytest.raises(reg.NoSuchResource) as e:
        await reg.build("k8s", agent_id=agent.id, name="web", session=_Session(agent, cluster), settings=None,
                        client_factory=None, cluster=str(uuid.uuid4()))
    assert "no such Kubernetes cluster" in str(e.value)
    with pytest.raises(reg.NoSuchResource):
        await reg.build("k8s", agent_id=agent.id, name="web", session=_Session(agent, cluster), settings=None,
                        client_factory=None, cluster="not-a-uuid")
    other = types.SimpleNamespace(id=uuid.uuid4(), name="mk2", agent_id=uuid.uuid4(), context=None, kubeconfig_path=None, inventory={})
    with pytest.raises(reg.NoSuchResource) as e:
        await reg.build("k8s", agent_id=agent.id, name="web", session=_Session(agent, other), settings=None,
                        client_factory=None, cluster=str(other.id))
    assert "access host" in str(e.value)


async def test_a_namespace_applied_or_deleted_through_bossman_refreshes_the_inventory(monkeypatch):
    """The explorer's namespace picker and the Application pre-flight read the cached inventory; a namespace
    Bossman itself creates (or deletes) must be in it at once, not after the poller's 15 minutes."""
    fake = Fake()
    gens: list = []
    r = _res(monkeypatch, fake, gens, kind="Namespace")
    refreshed = []

    async def fake_refresh(session, cluster, client, now):
        refreshed.append(cluster.name)
        return {"ok": True}

    class Session:
        async def commit(self):
            pass

    r._session = Session()
    monkeypatch.setattr(kubernetes_object.kubernetes, "refresh_inventory", fake_refresh)
    ns = {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "web-config"}}
    res = await r.apply({"manifest": ns, "require_approval": False}, dry_run=False)
    assert res["ok"] and refreshed == ["minikube"]
    await r.delete(preview=False)
    assert refreshed == ["minikube", "minikube"]


async def test_a_namespace_delete_preview_lists_what_it_still_contains(monkeypatch):
    fake = Fake(owned=[{"kind": "Deployment", "metadata": {"name": "web"}},
                       {"kind": "PersistentVolumeClaim", "metadata": {"name": "data"}},
                       {"kind": "ConfigMap", "metadata": {"name": "kube-root-ca.crt"}}])
    r = _res(monkeypatch, fake, [], kind="Namespace")
    r.namespace = None   # a Namespace is cluster-scoped
    out = await r.delete(preview=True)
    names = [(d["kind"], d["name"]) for d in out["dependents"]]
    assert ("Deployment", "web") in names and ("PersistentVolumeClaim", "data") in names
    assert ("ConfigMap", "kube-root-ca.crt") not in names


async def test_a_delete_passes_the_same_approval_gate_as_an_apply(monkeypatch):
    """YOLO mode off: deleting files a proposal carrying the delete preview and deletes nothing — the gate scale
    and apply use. With the waiver (approval itself), it deletes."""
    fake = Fake()
    gens: list = []
    filed: list = []
    r = _res(monkeypatch, fake, gens, yolo=False, proposals=filed)
    out = await r.delete(preview=False)
    assert out["awaiting_approval"] is True and out["deleted"] is False
    assert filed and filed[0]["delete"] is True and filed[0]["title"].startswith("Delete ConfigMap demo/web-config")
    assert "delete" not in [c["verb"] for c in fake.calls] and gens == []
    out = await r.delete(preview=False, require_approval=False)
    assert out["deleted"] is True and "delete" in [c["verb"] for c in fake.calls]
