"""THE DEPLOYMENT LIFECYCLE, live, against a real cluster (project kubernetes-console, plan V1).

This is an integration test against the RUNNING Bossman (BOSSMAN_URL, default http://localhost:8123) and a
registered, reachable Kubernetes cluster (BOSSMAN_K8S_CLUSTER, default: the first reachable one). It
skips — saying why — when either is missing. Every step reads the cluster back through Bossman after the
write, so the assertion is about what IS, not what the UI claims.

Steps (each a numbered assertion below): namespace → application by form (Deployment + Service) →
scale → image change with diff → a broken image shows as degraded with the reason → rollback by
generation → restart → logs → delete with preview → the deletion is a generation → namespace gone.
"""
from __future__ import annotations

import os
import time

import httpx
import pytest

from tests.naming import owned_name

BASE = os.environ.get("BOSSMAN_URL", "http://localhost:8123")
USER = os.environ.get("BOSSMAN_USER", "admin")
PASSWORD = os.environ.get("BOSSMAN_PASSWORD", "admin123")
WANT = os.environ.get("BOSSMAN_K8S_CLUSTER")


@pytest.fixture(scope="module")
def api():
    try:
        r = httpx.post(f"{BASE}/api/v1/auth/login", json={"username": USER, "password": PASSWORD}, timeout=10)
    except httpx.HTTPError as exc:
        pytest.skip(f"no running Bossman at {BASE}: {exc}")
    if r.status_code != 200:
        pytest.skip(f"login to {BASE} as {USER!r} failed: {r.status_code}")
    client = httpx.Client(base_url=BASE, headers={"Authorization": f"Bearer {r.json()['access_token']}"}, timeout=240)
    yield client
    client.close()


@pytest.fixture(scope="module")
def cluster(api):
    rows = api.get("/api/v1/kubernetes/clusters").json()
    rows = [c for c in rows if (not WANT or c["name"] == WANT)]
    live = [c for c in rows if c["reachability"] == "reachable"]
    if not live:
        pytest.skip(f"no reachable Kubernetes cluster registered{' named ' + WANT if WANT else ''} — "
                    f"registered: {[(c['name'], c['reachability'], c['unreachable_reason']) for c in rows]}")
    return live[0]


def _wait(fn, timeout=120, every=3):
    """Poll `fn` until it returns truthy; the last value is returned either way (so a failure names it)."""
    last = None
    deadline = time.time() + timeout
    while time.time() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(every)
    return last


def _ref(cluster, ns, kind, name, api_version="apps/v1"):
    return (f"/api/v1/agents/{cluster['agent_id']}/resources/k8s/{name}",
            {"cluster": cluster["id"], "namespace": ns, "api_version": api_version, "object_kind": kind})


def test_deployment_lifecycle_end_to_end(api, cluster):
    cid = cluster["id"]
    ns = owned_name("lifecycle")
    yolo = api.get("/api/v1/system/yolo-mode").json().get("yolo_mode")

    def objects(kind, namespace=ns):
        return api.get(f"/api/v1/kubernetes/clusters/{cid}/objects", params={"kind": kind, "namespace": namespace}).json()

    def form(image="nginx:1.27", replicas=1):
        return {"name": "web", "namespace": ns, "replicas": replicas, "create_namespace": True,
                "containers": [{"image": image, "ports": [{"port": 80}], "preset": "small"}],
                "expose": {"enabled": True, "type": "ClusterIP"},
                # nginx:1.27 runs as root by default; the Restricted profile would refuse it. Baseline keeps
                # the privilege-escalation and capability rules and is what a newcomer gets for a stock image.
                "security": {"profile": "baseline", "read_only_root_filesystem": False}}

    try:
        # 1 + 2 — preview says what will exist and why; the namespace is created with the application
        r = api.post(f"/api/v1/kubernetes/clusters/{cid}/applications/plan", json=form())
        assert r.status_code == 200, r.text
        plan = r.json()
        assert plan["kind"] == "Deployment" and [o["kind"] for o in plan["objects"]] == ["Namespace", "Service", "Deployment"]
        assert all(p["action"] == "create" and not p["refused"] for p in plan["plans"]), plan["plans"]
        assert not [i for i in plan["issues"] if i["level"] == "error"], plan["issues"]

        # 3 — apply (waived: this test IS the operator's approval; the gate itself is pinned offline)
        r = api.post(f"/api/v1/kubernetes/clusters/{cid}/applications/apply",
                     json={"form": form(), "dry_run": False, "require_approval": False, "note": "lifecycle step 3"})
        assert r.status_code == 200, r.text
        applied = r.json()
        assert applied["ok"] and applied["applied"] and [x["ok"] for x in applied["results"]] == [True, True, True], applied
        gens = {x["kind"]: x["generation"] for x in applied["results"]}
        assert gens["Deployment"] == 1 and gens["Service"] == 1

        rows = _wait(lambda: [x for x in objects("deployments")["items"] if x["name"] == "web" and x["state"]["state"] == "healthy"])
        assert rows, f"deployment did not become healthy: {objects('deployments')}"
        assert rows[0]["summary"]["ready"] == "1/1"
        pods = objects("pods")["items"]
        assert len(pods) == 1 and pods[0]["state"]["state"] == "healthy" and pods[0]["summary"]["qos"] == "Burstable"
        svc = [x for x in objects("services")["items"] if x["name"] == "web"][0]
        assert svc["summary"]["selector"] == {"app.kubernetes.io/name": "web", "app.kubernetes.io/instance": "web"}

        # 4 — scale to 3 through the same form (replicas is a field, not a different screen)
        r = api.post(f"/api/v1/kubernetes/clusters/{cid}/applications/apply",
                     json={"form": form(replicas=3), "dry_run": False, "require_approval": False, "note": "lifecycle step 4"})
        assert r.status_code == 200 and r.json()["ok"], r.text
        rows = _wait(lambda: [x for x in objects("deployments")["items"] if x["summary"]["ready"] == "3/3"])
        assert rows, objects("deployments")
        assert rows[0]["state"]["state"] == "healthy"

        # 5 — image change: the preview's diff names only the image, the rollout makes a new revision
        path, q = _ref(cluster, ns, "Deployment", "web")
        r = api.post(f"/api/v1/kubernetes/clusters/{cid}/applications/plan", json=form(image="nginx:1.28", replicas=3))
        dep_plan = [p for p in r.json()["plans"] if p["kind"] == "Deployment"][0]
        assert dep_plan["action"] == "update" and "nginx:1.28" in (dep_plan["diff_text"] or "") and "replicas" not in (dep_plan["diff_text"] or "").replace("replicas: 3", "")
        r = api.post(f"/api/v1/kubernetes/clusters/{cid}/applications/apply",
                     json={"form": form(image="nginx:1.28", replicas=3), "dry_run": False, "require_approval": False, "note": "lifecycle step 5"})
        assert r.status_code == 200 and r.json()["ok"], r.text
        rows = _wait(lambda: [x for x in objects("deployments")["items"] if x["summary"]["images"] == ["nginx:1.28"] and x["summary"]["ready"] == "3/3" and x["state"]["state"] == "healthy"])
        assert rows, objects("deployments")
        gens = api.get(path + "/generations", params=q).json()["generations"]
        assert [g["generation"] for g in gens][:3] == [3, 2, 1] and gens[0]["note"] == "lifecycle step 5"

        # 6 — a broken image: the row turns degraded and names the pod's reason, with the explanation
        r = api.post(f"/api/v1/kubernetes/clusters/{cid}/applications/apply",
                     json={"form": form(image="nginx:doesnotexist", replicas=3), "dry_run": False, "require_approval": False, "note": "lifecycle step 6"})
        assert r.status_code == 200 and r.json()["ok"], r.text
        rows = _wait(lambda: [x for x in objects("deployments")["items"] if x["state"]["state"] == "degraded"])
        assert rows, objects("deployments")
        st = rows[0]["state"]
        assert st["reason"] in ("ImagePullBackOff", "ErrImagePull") and st["detail"].startswith("pod ")
        assert st["explain"]["title"] in ("Image cannot be pulled", "Image pull failed") and st["explain"]["fix"]
        ev = api.get(f"/api/v1/kubernetes/clusters/{cid}/events", params={"namespace": ns}).json()["events"]
        assert any(e["type"] == "Warning" and "doesnotexist" in (e["message"] or "") for e in ev)

        # 7 — rollback to generation 3 (nginx:1.28): a NEW generation, and the cluster follows
        r = api.post(path + "/rollback", params=q, json={"generation": 3})
        assert r.status_code == 200, r.text
        rb = r.json()
        if rb.get("awaiting_approval"):
            r = api.post(f"/api/v1/change-proposals/{rb['proposal_id']}/approve")
            assert r.status_code == 200 and r.json()["status"] == "applied", r.text
        else:
            assert rb["ok"] and rb["applied"], rb
        rows = _wait(lambda: [x for x in objects("deployments")["items"] if x["summary"]["images"] == ["nginx:1.28"] and x["state"]["state"] == "healthy" and x["summary"]["ready"] == "3/3"])
        assert rows, objects("deployments")
        gens = api.get(path + "/generations", params=q).json()["generations"]
        assert gens[0]["generation"] == 5 and "rollback to gen 3" in (gens[0]["note"] or "")
        one = api.get(f"/api/v1/kubernetes/clusters/{cid}/objects/deployments/web", params={"namespace": ns}).json()
        assert "bossman" in one["field_managers"] and one["etcd_key"] == f"/registry/deployments/{ns}/web"

        # 8 — logs of a running pod
        pod = [p for p in objects("pods")["items"] if p["state"]["state"] == "healthy"][0]
        lg = api.get(f"/api/v1/kubernetes/clusters/{cid}/logs", params={"namespace": ns, "pod": pod["name"], "tail": 20}).json()
        assert not lg.get("error") and lg["lines"], lg

        # 9 — edit: the live application comes back as the form
        back = api.get(f"/api/v1/kubernetes/clusters/{cid}/applications/{ns}/web").json()
        assert back["kind"] == "Deployment" and back["form"]["replicas"] == 3 and back["form"]["containers"][0]["image"] == "nginx:1.28"
        assert back["form"]["expose"]["enabled"] and "Service" in back["related"]

        # 10 — delete with preview: the ReplicaSets and pods go with it, the Service does not
        r = api.delete(path + "/object", params={**q, "preview": "true"})
        pv = r.json()
        assert pv["ok"] and pv["preview"] and any(d["kind"] == "Pod" for d in pv["dependents"]) and any(d["kind"] == "ReplicaSet" for d in pv["dependents"])
        r = api.delete(path + "/object", params={**q, "preview": "false", "note": "lifecycle step 10"})
        assert r.status_code == 200 and r.json()["ok"], r.text
        if r.json().get("awaiting_approval"):
            # A delete needs a second look when the approval guardrail is on: it becomes a change proposal and
            # NOTHING is deleted until someone approves it — then the deletion happens and is a generation.
            assert r.json()["deleted"] is False and r.json()["status"] == "pending_approval", r.text
            assert [x for x in objects("deployments")["items"] if x["name"] == "web"], "deleted before approval"
            a = api.post(f"/api/v1/change-proposals/{r.json()['proposal_id']}/approve")
            assert a.status_code == 200 and a.json()["status"] in ("applied", "approved"), a.text
        else:
            assert r.json()["deleted"] and r.json()["generation"] == 6, r.text
        gone = _wait(lambda: not [x for x in objects("deployments")["items"] if x["name"] == "web"])
        assert gone, objects("deployments")
        # 11 — nothing vanished silently: the deletion is the newest generation
        gens = api.get(path + "/generations", params=q).json()["generations"]
        assert gens[0]["spec"].get("deleted") is True and gens[0]["generation"] == 6
        assert api.get(path + "/observe", params=q).json()["observed"] is None
    finally:
        # 12 — the namespace goes, and the explorer shows it terminating, then gone
        npath, nq = _ref(cluster, None, "Namespace", ns, "v1")
        nq.pop("namespace")
        d = api.delete(npath + "/object", params={**nq, "preview": "false", "note": "lifecycle cleanup"})
        if d.status_code == 200 and d.json().get("awaiting_approval"):
            # Under the approval guardrail the cleanup is a proposal too — unapproved, it left one namespace (and
            # its pods) behind per run: three were found on 2026-10-10, holding node resources.
            api.post(f"/api/v1/change-proposals/{d.json()['proposal_id']}/approve")
        _wait(lambda: not [x for x in objects("namespaces", None)["items"] if x["name"] == ns], timeout=90)
