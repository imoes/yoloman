"""Kubernetes clusters (project kubernetes-console): the entity, its API, and the state vocabulary.

The API tests inject a fake AgentClient through get_client_factory (the seam api/management.py's tests use)
that answers `kubectl` module calls per verb, so no cluster is needed; the classification tests are pure
functions over real-shaped objects. The LIVE lifecycle against minikube lives in
test_kubernetes_lifecycle_live.py and skips without a reachable cluster.
"""
from __future__ import annotations

import json
import types
import uuid

from fastapi.testclient import TestClient

from bossman.api.plans import get_client_factory
from bossman.db.models import Agent, KubernetesCluster
from bossman.main import create_app
from bossman.services import kubernetes
from bossman.services.agent_client import AgentClientError
from bossman.services.auth import new_api_token
from tests.naming import owned_name


# ---- a fake access host whose kubectl answers per verb -------------------------------------------

NODE = {"kind": "Node", "apiVersion": "v1",
        "metadata": {"name": "n1", "labels": {"node-role.kubernetes.io/control-plane": ""}, "creationTimestamp": "2026-10-01T00:00:00Z"},
        "spec": {}, "status": {"conditions": [{"type": "Ready", "status": "True"}],
                               "addresses": [{"type": "InternalIP", "address": "192.168.49.2"}],
                               "nodeInfo": {"kubeletVersion": "v1.35.1"},
                               "capacity": {"cpu": "8", "memory": "16Gi"}, "allocatable": {"cpu": "8", "memory": "15Gi"}}}
NS = {"kind": "Namespace", "apiVersion": "v1",
      "metadata": {"name": "demo", "labels": {"pod-security.kubernetes.io/enforce": "restricted"}, "creationTimestamp": "2026-10-01T00:00:00Z"},
      "status": {"phase": "Active"}}
API_RESOURCES = (
    "NAME          SHORTNAMES   APIVERSION   NAMESPACED   KIND         VERBS                                        CATEGORIES\n"
    "configmaps    cm           v1           true         ConfigMap    create,delete,get,list,patch,update,watch    \n"
    "nodes         no           v1           false        Node         create,delete,get,list,patch,update,watch    \n"
    "deployments   deploy       apps/v1      true         Deployment   create,delete,get,list,patch,update,watch    all\n"
)
DEPLOY_OK = {"kind": "Deployment", "apiVersion": "apps/v1",
             "metadata": {"name": "web", "namespace": "demo", "generation": 2, "creationTimestamp": "2026-10-01T00:00:00Z",
                          "labels": {"app.kubernetes.io/name": "web"}},
             "spec": {"replicas": 3, "selector": {"matchLabels": {"app": "web"}},
                      "template": {"spec": {"containers": [{"name": "web", "image": "nginx:1.27"}]}}},
             "status": {"observedGeneration": 2, "replicas": 3, "readyReplicas": 3, "updatedReplicas": 3, "availableReplicas": 3,
                        "conditions": [{"type": "Available", "status": "True"}, {"type": "Progressing", "status": "True", "reason": "NewReplicaSetAvailable"}]}}


class KubectlFake:
    """Answers `call_tool("kubectl", params)` like the module does: {changed, msg, data{rc, stdout, stderr, parsed}}."""

    def __init__(self, reachable: bool = True, host_down: bool = False):
        self.reachable, self.host_down = reachable, host_down
        self.calls: list[dict] = []
        self._timeout = None

    def _ok(self, doc, stderr=""):
        text = json.dumps(doc) if not isinstance(doc, str) else doc
        return {"changed": False, "msg": "kubectl", "data": {"rc": 0, "stdout": text, "stderr": stderr,
                                                             **({"parsed": doc} if not isinstance(doc, str) else {})}}

    async def call_tool(self, name, body):
        assert name == "kubectl", name
        self.calls.append(body)
        if self.host_down:
            raise AgentClientError("10.0.0.9:8010: request failed: connection refused")
        verb, res = body.get("verb"), body.get("resource", "")
        if verb == "version":
            if not self.reachable:
                return {"changed": False, "msg": "kubectl version failed", "data": {
                    "rc": 1, "stdout": json.dumps({"clientVersion": {"gitVersion": "v1.35.1"}}),
                    "stderr": "The connection to the server 192.168.49.2:8443 was refused - did you specify the right host or port?",
                    "parsed": {"clientVersion": {"gitVersion": "v1.35.1"}}}}
            return self._ok({"clientVersion": {"gitVersion": "v1.35.1"}, "serverVersion": {"gitVersion": "v1.35.1"}})
        if verb == "config view":
            return self._ok({"clusters": [{"name": "x", "cluster": {"server": "https://192.168.49.2:8443"}}]})
        if verb == "api-resources":
            return self._ok(API_RESOURCES)
        if verb == "get" and res == "nodes":
            return self._ok({"kind": "List", "items": [NODE]})
        if verb == "get" and res == "namespaces":
            return self._ok({"kind": "List", "items": [NS]})
        if verb == "get" and res == "events":
            return self._ok({"kind": "List", "items": []})
        if verb == "get" and res.startswith("deployments,"):
            return self._ok({"kind": "List", "items": [DEPLOY_OK]})
        if verb == "get" and res in ("deployments", "deployment") and body.get("name") == "web":
            return self._ok(DEPLOY_OK)
        if verb == "get" and res in ("deployments", "deployment") and body.get("name"):
            return {"changed": False, "msg": "kubectl get failed", "data": {
                "rc": 1, "stdout": "", "stderr": f'Error from server (NotFound): deployments.apps "{body["name"]}" not found'}}
        if verb == "get" and res in ("deployments", "deployment"):
            return self._ok({"kind": "List", "items": [DEPLOY_OK]})
        return self._ok({"kind": "List", "items": []})


async def _make_agent(db_session, **overrides) -> Agent:
    fields = {"name": owned_name("k8s-access"), "token": "tok", "address": "10.0.0.9:8010",
              "mode": "satellite", "enrollment_state": "enrolled"}
    fields.update(overrides)
    agent = Agent(**fields)
    db_session.add(agent)
    await db_session.flush()
    await db_session.commit()
    return agent


async def _make_api_token(db_session):
    from bossman.db.models import AccessGrant

    row, raw = new_api_token(owned_name("k8s-caller"))
    db_session.add(row)
    await db_session.flush()
    db_session.add(AccessGrant(subject_kind="api_token", subject_ref=row.name, subject_token_id=row.id, scope="all"))
    await db_session.flush()
    await db_session.commit()
    return row, raw


def _client(fake):
    """A started app (lifespan runs → session_factory exists) whose agent client is the fake."""
    app = create_app()
    app.dependency_overrides[get_client_factory] = lambda: (lambda agent, settings: fake)
    return TestClient(app).__enter__()


async def test_register_probes_lists_updates_and_forgets(db_session):
    agent = await _make_agent(db_session)
    _row, raw = await _make_api_token(db_session)
    h = {"Authorization": f"Bearer {raw}"}
    fake = KubectlFake()
    c = _client(fake)
    name = owned_name("k8s-cluster")

    r = c.post("/api/v1/kubernetes/clusters", json={"name": name, "agent_id": str(agent.id)}, headers=h)
    assert r.status_code == 201, r.text
    body = r.json()
    # registration probed the cluster: reachable, version and counts come from the access host
    assert body["reachability"] == "reachable" and body["unreachable_reason"] is None
    assert body["server_version"] == "v1.35.1" and body["node_count"] == 1 and body["namespace_count"] == 1
    assert body["server_url"] == "https://192.168.49.2:8443"
    assert body["agent_name"] == agent.name
    cid = body["id"]
    verbs = [x["verb"] for x in fake.calls]
    assert verbs[0] == "version" and "api-resources" in verbs

    # a second cluster with the same name is refused with the reason
    r = c.post("/api/v1/kubernetes/clusters", json={"name": name, "agent_id": str(agent.id)}, headers=h)
    assert r.status_code == 409 and "already exists" in r.json()["detail"]

    r = c.get("/api/v1/kubernetes/clusters", headers=h)
    assert any(x["id"] == cid for x in r.json())

    # the inventory is served from the cache (no new kubectl call) and says when it was observed
    before = len(fake.calls)
    r = c.get(f"/api/v1/kubernetes/clusters/{cid}/inventory", headers=h)
    assert r.status_code == 200
    inv = r.json()
    assert inv["stale"] is False and inv["observed_at"] and len(fake.calls) == before
    assert inv["inventory"]["nodes"][0]["name"] == "n1" and inv["inventory"]["nodes"][0]["roles"] == ["control-plane"]
    assert inv["inventory"]["namespaces"][0]["pod_security"] == {"enforce": "restricted"}
    assert [a["kind"] for a in inv["inventory"]["api_resources"]] == ["ConfigMap", "Node", "Deployment"]
    assert inv["inventory"]["api_resources"][0]["short_names"] == ["cm"]
    assert inv["inventory"]["workloads"]["totals"] == {"Deployment": 1}
    assert inv["inventory"]["storage_classes"] == [] and inv["inventory"]["ingress_classes"] == [] and inv["inventory"]["quotas"] == []

    # stale If-Match → 412; fresh → the name changes
    r = c.put(f"/api/v1/kubernetes/clusters/{cid}", json={"name": name + "-x", "agent_id": str(agent.id)},
              headers={**h, "If-Match": "deadbeefdeadbeef"})
    assert r.status_code == 412
    r = c.put(f"/api/v1/kubernetes/clusters/{cid}", json={"name": name + "-x", "agent_id": str(agent.id)},
              headers={**h, "If-Match": body["version"]})
    assert r.status_code == 200 and r.json()["name"] == name + "-x"
    # a rename does not throw the observed facts away (same access path)
    assert r.json()["reachability"] == "reachable"

    r = c.delete(f"/api/v1/kubernetes/clusters/{cid}", headers=h)
    assert r.status_code == 204
    assert c.get(f"/api/v1/kubernetes/clusters/{cid}", headers=h).status_code == 404
    await db_session.delete(await db_session.get(Agent, agent.id))
    await db_session.commit()


async def test_unreachable_is_a_named_state_with_the_reason(db_session):
    agent = await _make_agent(db_session)
    _row, raw = await _make_api_token(db_session)
    h = {"Authorization": f"Bearer {raw}"}
    c = _client(KubectlFake(reachable=False))
    r = c.post("/api/v1/kubernetes/clusters", json={"name": owned_name("k8s-down"), "agent_id": str(agent.id)}, headers=h)
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["reachability"] == "unreachable"
    assert "connection to the server" in body["unreachable_reason"]
    cid = body["id"]
    # no cache and still unreachable → 502 carrying the reason, not an empty inventory
    r = c.get(f"/api/v1/kubernetes/clusters/{cid}/inventory", headers=h)
    assert r.status_code == 502 and "connection to the server" in r.json()["detail"]["reason"]
    # the access host itself down → the reason names the host, not kubectl
    c2 = _client(KubectlFake(host_down=True))
    r = c2.post(f"/api/v1/kubernetes/clusters/{cid}/probe", headers=h)
    assert r.status_code == 200 and r.json()["reachability"] == "unreachable"
    assert "access host unreachable" in r.json()["reason"]
    c.delete(f"/api/v1/kubernetes/clusters/{cid}", headers=h)
    await db_session.delete(await db_session.get(Agent, agent.id))
    await db_session.commit()


async def test_objects_and_one_object_carry_state_and_versions(db_session):
    agent = await _make_agent(db_session)
    _row, raw = await _make_api_token(db_session)
    h = {"Authorization": f"Bearer {raw}"}
    fake = KubectlFake()
    c = _client(fake)
    cid = c.post("/api/v1/kubernetes/clusters", json={"name": owned_name("k8s-obj"), "agent_id": str(agent.id)}, headers=h).json()["id"]

    r = c.get(f"/api/v1/kubernetes/clusters/{cid}/objects", params={"kind": "deployments", "namespace": "demo"}, headers=h)
    assert r.status_code == 200, r.text
    rows = r.json()["items"]
    assert rows[0]["name"] == "web" and rows[0]["state"]["state"] == "healthy"
    assert rows[0]["summary"]["ready"] == "3/3" and rows[0]["summary"]["images"] == ["nginx:1.27"]
    assert fake.calls[-1]["namespace"] == "demo" and fake.calls[-1]["resource"] == "deployments"

    r = c.get(f"/api/v1/kubernetes/clusters/{cid}/objects/deployments/web", params={"namespace": "demo"}, headers=h)
    assert r.status_code == 200
    one = r.json()
    assert one["spec"]["replicas"] == 3 and one["status"]["readyReplicas"] == 3
    assert one["versions"]["generation"] == 2 and one["versions"]["observed_generation"] == 2
    # the etcd key is the community layout, computed from the inventory's api-resources plural
    assert one["etcd_key"] == "/registry/deployments/demo/web"

    r = c.get(f"/api/v1/kubernetes/clusters/{cid}/objects/deployments/nope", params={"namespace": "demo"}, headers=h)
    assert r.status_code == 404 and "NotFound" in r.json()["detail"]

    c.delete(f"/api/v1/kubernetes/clusters/{cid}", headers=h)
    await db_session.delete(await db_session.get(Agent, agent.id))
    await db_session.commit()


# ---- the state vocabulary: exhaustive, each with its reason ---------------------------------------

def _pod(phase="Running", ready="True", statuses=None, deleting=False, scheduled=None):
    pod = {"kind": "Pod", "metadata": {"name": "p", "namespace": "demo"},
           "spec": {"containers": [{"name": "web", "image": "nginx:1.27"}]},
           "status": {"phase": phase, "conditions": [{"type": "Ready", "status": ready}],
                      "containerStatuses": statuses if statuses is not None else [{"name": "web", "ready": ready == "True", "restartCount": 0, "state": {"running": {}}}]}}
    if deleting:
        pod["metadata"]["deletionTimestamp"] = "2026-10-09T10:00:00Z"
    if scheduled is not None:
        pod["status"]["conditions"].append({"type": "PodScheduled", "status": scheduled, "reason": "Unschedulable",
                                            "message": "0/1 nodes are available: 1 Insufficient cpu."})
    return pod


def test_pod_states_are_named_and_explained():
    assert kubernetes.classify(_pod())["state"] == "healthy"
    s = kubernetes.classify(_pod("Pending", "False", statuses=[{"name": "web", "ready": False, "restartCount": 0,
                                                                "state": {"waiting": {"reason": "ImagePullBackOff", "message": "Back-off pulling image"}}}]))
    assert s["state"] == "degraded" and s["reason"] == "ImagePullBackOff"
    assert s["explain"]["title"] == "Image cannot be pulled" and s["explain"]["fix"] and s["explain"]["doc"]
    s = kubernetes.classify(_pod("Running", "False", statuses=[{"name": "web", "ready": False, "restartCount": 7,
                                                                "state": {"waiting": {"reason": "CrashLoopBackOff"}},
                                                                "lastState": {"terminated": {"exitCode": 137, "reason": "OOMKilled"}}}]))
    assert s["state"] == "degraded" and s["reason"] == "OOMKilled" and "exited 137" in s["detail"]
    s = kubernetes.classify(_pod("Pending", "False", statuses=[], scheduled="False"))
    assert s["state"] == "pending" and s["reason"] == "Unschedulable" and "Insufficient cpu" in s["detail"]
    assert kubernetes.classify(_pod(deleting=True))["state"] == "terminating"
    assert kubernetes.classify(_pod("Succeeded"))["state"] == "completed"
    assert kubernetes.classify(_pod("Failed"))["state"] == "failed"
    assert kubernetes.classify(_pod("Unknown"))["state"] == "unknown"
    s = kubernetes.classify(_pod("Running", "False"))
    assert s["state"] == "progressing"


def test_workload_states_follow_the_controller_conditions():
    assert kubernetes.classify(DEPLOY_OK)["state"] == "healthy"
    stalled = json.loads(json.dumps(DEPLOY_OK))
    stalled["status"].update({"readyReplicas": 1, "updatedReplicas": 1, "conditions": [
        {"type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded", "message": "ReplicaSet web-abc has timed out progressing."}]})
    s = kubernetes.classify(stalled)
    assert s["state"] == "failed" and s["reason"] == "ProgressDeadlineExceeded" and "Rollout stalled" == s["explain"]["title"]
    rolling = json.loads(json.dumps(DEPLOY_OK))
    rolling["status"].update({"readyReplicas": 2, "updatedReplicas": 1})
    assert kubernetes.classify(rolling)["state"] == "progressing"
    zero = json.loads(json.dumps(DEPLOY_OK))
    zero["spec"]["replicas"] = 0
    assert kubernetes.classify(zero)["state"] == "suspended"
    paused = json.loads(json.dumps(DEPLOY_OK))
    paused["spec"]["paused"] = True
    assert kubernetes.classify(paused)["reason"] == "Paused"
    # a kind without runtime status is `static`, never a blank
    assert kubernetes.classify({"kind": "ConfigMap", "metadata": {"name": "c"}})["state"] == "static"
    job = {"kind": "Job", "metadata": {}, "spec": {}, "status": {"conditions": [{"type": "Complete", "status": "True"}], "succeeded": 1}}
    assert kubernetes.classify(job)["state"] == "completed"
    cron = {"kind": "CronJob", "metadata": {}, "spec": {"schedule": "* * * * *", "suspend": True}, "status": {}}
    assert kubernetes.classify(cron)["state"] == "suspended"
    node = json.loads(json.dumps(NODE))
    node["spec"]["unschedulable"] = True
    assert kubernetes.classify(node)["reason"] == "Cordoned"
    for st in [kubernetes.classify(x) for x in (DEPLOY_OK, stalled, rolling, zero, paused, job, cron, node, NODE, NS)]:
        assert st["state"] in kubernetes.STATES


def test_a_rolling_workload_takes_its_degraded_pods_reason():
    rolling = json.loads(json.dumps(DEPLOY_OK))
    rolling["status"].update({"readyReplicas": 0, "updatedReplicas": 1, "availableReplicas": 0})
    rows = [kubernetes.row(rolling)]
    assert rows[0]["state"]["state"] == "progressing"
    pod = _pod("Pending", "False", statuses=[{"name": "web", "ready": False, "restartCount": 0,
                                               "state": {"waiting": {"reason": "ImagePullBackOff", "message": "Back-off pulling image"}}}])
    pod["metadata"]["labels"] = {"app": "web"}
    other = _pod("Running"); other["metadata"]["labels"] = {"app": "other"}
    kubernetes.refine_with_pods(rows, [rolling], [other, pod])
    assert rows[0]["state"]["state"] == "degraded" and rows[0]["state"]["reason"] == "ImagePullBackOff"
    assert rows[0]["state"]["detail"].startswith("pod p:") and rows[0]["state"]["explain"]["title"]
    # a healthy workload is never repainted by a stray pod
    ok = [kubernetes.row(DEPLOY_OK)]
    kubernetes.refine_with_pods(ok, [DEPLOY_OK], [pod])
    assert ok[0]["state"]["state"] == "healthy"


def test_api_resources_table_is_parsed_by_column_offsets():
    rows = kubernetes.parse_api_resources(API_RESOURCES)
    assert [r["name"] for r in rows] == ["configmaps", "nodes", "deployments"]
    assert rows[1]["namespaced"] is False and rows[2]["group"] == "apps" and rows[2]["version"] == "v1"
    assert rows[2]["categories"] == ["all"] and "patch" in rows[0]["verbs"]


def test_selector_rendering_covers_match_expressions():
    assert kubernetes.selector_of(DEPLOY_OK) == "app=web"
    obj = {"kind": "Deployment", "spec": {"selector": {"matchLabels": {"a": "1"}, "matchExpressions": [
        {"key": "tier", "operator": "In", "values": ["web", "api"]}, {"key": "canary", "operator": "DoesNotExist"}]}}}
    assert kubernetes.selector_of(obj) == "a=1,tier in (web,api),!canary"
    assert kubernetes.selector_of({"kind": "Service", "spec": {"selector": {"app": "web", "tier": "fe"}}}) == "app=web,tier=fe"


def test_actions_are_greyed_out_with_a_reason():
    cordoned = {"kind": "Node", "metadata": {"name": "n1"}, "spec": {"unschedulable": True}}
    assert kubernetes.action_available("cordon", "Node", cordoned) == (False, "already cordoned")
    assert kubernetes.action_available("uncordon", "Node", cordoned)[0] is True
    assert kubernetes.action_available("restart", "ConfigMap")[0] is False and "Deployment" in kubernetes.action_available("restart", "ConfigMap")[1]
    assert kubernetes.action_available("suspend_job", "CronJob", {"spec": {"suspend": True}}) == (False, "already suspended")
    assert kubernetes.action_available("nope", "Pod")[0] is False
    for a in kubernetes.ACTIONS:
        ok, why = kubernetes.action_available(a, "Deployment", DEPLOY_OK)
        assert why                                                    # every answer carries a reason or a meaning


async def test_actions_build_the_right_argv():
    calls = []

    class C:
        _timeout = None
        async def call_tool(self, name, body):
            calls.append(body)
            return {"changed": True, "msg": "ok", "data": {"rc": 0, "stdout": "deployment.apps/web restarted\n", "stderr": ""}}

    cl = types.SimpleNamespace(id="c", name="mk", context=None, kubeconfig_path=None, inventory={})
    import types as _t  # noqa
    cluster = cl
    res = await kubernetes.run_action(C(), cluster, "restart", "Deployment", "web", "demo")
    assert res["ok"] and calls[-1]["verb"] == "rollout restart" and calls[-1]["resource"] == "deployment/web" and calls[-1]["namespace"] == "demo"
    await kubernetes.run_action(C(), cluster, "undo", "Deployment", "web", "demo", revision=2)
    assert calls[-1]["args"] == ["--to-revision=2"]
    await kubernetes.run_action(C(), cluster, "drain", "Node", "n1", None, force=True)
    assert calls[-1]["verb"] == "drain" and calls[-1]["resource"] == "n1" and "--ignore-daemonsets" in calls[-1]["args"] and "--force" in calls[-1]["args"] and "namespace" not in calls[-1]
    await kubernetes.run_action(C(), cluster, "suspend_job", "CronJob", "nightly", "demo")
    assert calls[-1]["verb"] == "patch" and calls[-1]["args"][-1] == '{"spec":{"suspend":true}}'
    await kubernetes.run_action(C(), cluster, "delete_pod", "Pod", "web-1", "demo", grace_period=0)
    assert calls[-1]["verb"] == "delete" and calls[-1]["resource"] == "pod" and calls[-1]["name"] == "web-1" and "--grace-period=0" in calls[-1]["args"]
    assert kubernetes.parse_rollout_history("REVISION  CHANGE-CAUSE\n1         <none>\n2         kubectl set image\n") == [
        {"revision": 1, "change_cause": "<none>"}, {"revision": 2, "change_cause": "kubectl set image"}]
