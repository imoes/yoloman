"""Kubernetes clusters, administered through an ACCESS HOST (project kubernetes-console).

Every call here is `access host agent → kubectl module → API server`. Bossman stores no cluster
credential (the kubeconfig stays on the host) and never reads or writes etcd: the API server is the
cluster's only writer, by design, and this module only ever talks to it — through the host, the way the
Helm tier already does (helm_app.py), so mTLS, the agent's write gate, its ACL and the operation log all
apply without a second enforcement path.

Three jobs live here:

* `call` — one kubectl invocation, typed. A non-zero exit is DATA (rc + stderr), the reason an operator
  acts on; only a transport failure is an exception.
* the INVENTORY — what the explorer opens from: nodes, namespaces, api-resources, a workload summary. It
  is cached on the KubernetesCluster row (poller-refreshed, `?refresh=true` for live) so the console loads
  in milliseconds, and the cache is labelled as such.
* `classify_*` — the one exhaustive state vocabulary for every object (healthy | progressing | degraded |
  failed | completed | suspended | pending | terminating | unknown | static), each state with the Kubernetes
  `reason` that produced it and, where the reasons table knows it, the plain-language explanation and fix.
  Nothing is "red" without the reader being able to reach why.
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.db.models import Agent, KubernetesCluster
from bossman.services.agent_client import AgentClientError

logger = logging.getLogger(__name__)

#: How long the inventory cache is trusted before the poller refreshes it.
INVENTORY_MAX_AGE = timedelta(minutes=15)

#: The server-side-apply field manager the agent module uses (internal/modules/kubectl.go) — named here so
#: `kubectl diff --server-side` previews ownership exactly as the apply will claim it.
KUBECTL_FIELD_MANAGER_NAME = "bossman"

#: kubectl calls can be slow on a busy API server; the default 30 s client timeout is for agent reads.
KUBECTL_TIMEOUT_SECONDS = 90

STATES = ("healthy", "progressing", "degraded", "failed", "completed", "suspended",
          "pending", "terminating", "unknown", "static")


class KubectlFailed(Exception):
    """kubectl ran and exited non-zero. `rc`/`stderr` carry the server's reason verbatim."""

    def __init__(self, verb: str, rc: int, stderr: str):
        super().__init__(f"kubectl {verb} failed (rc {rc}): {stderr.strip()[:500] or 'no stderr'}")
        self.verb, self.rc, self.stderr = verb, rc, stderr


# ---------------------------------------------------------------------------
# the reasons table — Kubernetes `reason` → what it means and what to do
# ---------------------------------------------------------------------------

def _reasons_path() -> Path | None:
    for cand in (
        Path(os.environ.get("AGENTIC_CONFIGS_DIR") or "/nonexistent") / "kubernetes_reasons.json",
        Path("/app/configs/kubernetes_reasons.json"),
        Path(__file__).resolve().parents[3] / "configs" / "kubernetes_reasons.json",
    ):
        if cand.is_file():
            return cand
    return None


@lru_cache(maxsize=1)
def reasons_table() -> dict[str, dict[str, str]]:
    """`configs/kubernetes_reasons.json` → {reason: {title, explanation, fix, doc}}. Missing file = empty
    table, never an error: a reason the table does not know is still shown, just without the explanation."""
    path = _reasons_path()
    if path is None:
        return {}
    try:
        doc = json.loads(path.read_text())
    except (OSError, ValueError):
        logger.exception("kubernetes_reasons.json unreadable")
        return {}
    return {k: v for k, v in (doc.get("reasons") or {}).items() if isinstance(v, dict)}


def explain(reason: str | None) -> dict[str, Any] | None:
    if not reason:
        return None
    entry = reasons_table().get(reason)
    return {"reason": reason, **entry} if entry else {"reason": reason}


# ---------------------------------------------------------------------------
# one kubectl call
# ---------------------------------------------------------------------------

async def call(client, cluster: KubernetesCluster, **params: Any) -> dict[str, Any]:
    """Run one kubectl verb on the access host and return the module's data: {rc, stdout, stderr, parsed?}.

    Raises KubectlFailed on a non-zero exit (other than `diff`'s rc 1, which is data), AgentClientError
    when the host itself cannot be reached. The cluster's context/kubeconfig are added here so no caller
    can forget them and silently hit the host's current-context."""
    if cluster.context:
        params.setdefault("context", cluster.context)
    if cluster.kubeconfig_path:
        params.setdefault("kubeconfig", cluster.kubeconfig_path)
    client._timeout = KUBECTL_TIMEOUT_SECONDS  # noqa: SLF001 — one construction path, see client_for
    result = await client.call_tool("kubectl", params)
    data = (result or {}).get("data") if isinstance(result, dict) else None
    if not isinstance(data, dict):
        raise AgentClientError("kubectl module returned no data — is the access host's agent current?")
    rc = data.get("rc")
    verb = str(params.get("verb"))
    if rc not in (0, None) and not (verb == "diff" and rc == 1):
        raise KubectlFailed(verb, int(rc), str(data.get("stderr") or ""))
    return data


def _parsed(data: dict[str, Any]) -> Any:
    if "parsed" in data:
        return data["parsed"]
    try:
        return json.loads(data.get("stdout") or "null")
    except ValueError:
        return None


def _items(data: dict[str, Any]) -> list[dict[str, Any]]:
    doc = _parsed(data)
    if isinstance(doc, dict) and isinstance(doc.get("items"), list):
        return [i for i in doc["items"] if isinstance(i, dict)]
    if isinstance(doc, dict) and doc.get("kind"):
        return [doc]
    return []


# ---------------------------------------------------------------------------
# reachability + inventory
# ---------------------------------------------------------------------------

def _age(ts: str | None, now: datetime | None = None) -> int | None:
    """Seconds since an RFC3339 timestamp — the unit the UI formats; None when absent."""
    if not ts:
        return None
    try:
        then = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    return int(((now or datetime.now(timezone.utc)) - then).total_seconds())


def _conditions(obj: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {c.get("type"): c for c in ((obj.get("status") or {}).get("conditions") or []) if isinstance(c, dict)}


async def probe(client, cluster: KubernetesCluster) -> dict[str, Any]:
    """Can the access host reach the API server right now, and what is it? One `kubectl version`:
    the client half always prints, the server half only on success, and stderr says why not."""
    try:
        data = await call(client, cluster, verb="version")
    except KubectlFailed as exc:
        return {"reachable": False, "reason": exc.stderr.strip().splitlines()[0] if exc.stderr.strip() else str(exc)}
    doc = _parsed(data) or {}
    server = (doc.get("serverVersion") or {}).get("gitVersion") if isinstance(doc, dict) else None
    if not server:
        return {"reachable": False, "reason": (data.get("stderr") or "kubectl version returned no serverVersion").strip()[:300]}
    return {"reachable": True, "server_version": server,
            "client_version": (doc.get("clientVersion") or {}).get("gitVersion")}


async def _server_url(client, cluster: KubernetesCluster) -> str | None:
    try:
        data = await call(client, cluster, verb="config view", output="json", args=["--minify"])
    except (KubectlFailed, AgentClientError):
        return None
    doc = _parsed(data) or {}
    for c in (doc.get("clusters") or []) if isinstance(doc, dict) else []:
        server = ((c or {}).get("cluster") or {}).get("server")
        if server:
            return server
    return None


def summarize_node(n: dict[str, Any]) -> dict[str, Any]:
    md, spec, st = n.get("metadata") or {}, n.get("spec") or {}, n.get("status") or {}
    conds = _conditions(n)
    labels = md.get("labels") or {}
    roles = sorted(k.split("/", 1)[1] for k in labels if k.startswith("node-role.kubernetes.io/")) or ["worker"]
    addrs = {a.get("type"): a.get("address") for a in (st.get("addresses") or [])}
    info = st.get("nodeInfo") or {}
    return {
        "name": md.get("name"), "roles": roles,
        "ready": (conds.get("Ready") or {}).get("status", "Unknown"),
        "unschedulable": bool(spec.get("unschedulable")),
        "taints": [f"{t.get('key')}={t.get('value', '')}:{t.get('effect')}" for t in (spec.get("taints") or [])],
        "pressure": [t for t in ("MemoryPressure", "DiskPressure", "PIDPressure", "NetworkUnavailable")
                     if (conds.get(t) or {}).get("status") == "True"],
        "internal_ip": addrs.get("InternalIP"), "hostname": addrs.get("Hostname"),
        "kubelet_version": info.get("kubeletVersion"), "os_image": info.get("osImage"),
        "container_runtime": info.get("containerRuntimeVersion"), "kernel": info.get("kernelVersion"),
        "capacity": {k: st.get("capacity", {}).get(k) for k in ("cpu", "memory", "pods", "ephemeral-storage")},
        "allocatable": {k: st.get("allocatable", {}).get(k) for k in ("cpu", "memory", "pods", "ephemeral-storage")},
        "age_seconds": _age(md.get("creationTimestamp")),
        "state": classify(n),
    }


def summarize_namespace(ns: dict[str, Any]) -> dict[str, Any]:
    md, st = ns.get("metadata") or {}, ns.get("status") or {}
    labels = md.get("labels") or {}
    pss = {m: labels.get(f"pod-security.kubernetes.io/{m}") for m in ("enforce", "audit", "warn")}
    return {
        "name": md.get("name"), "phase": st.get("phase"),
        "pod_security": {k: v for k, v in pss.items() if v},
        "system": md.get("name", "").startswith("kube-") or md.get("name") == "default",
        "age_seconds": _age(md.get("creationTimestamp")),
        "state": classify(ns),
    }


def parse_api_resources(text: str) -> list[dict[str, Any]]:
    """`kubectl api-resources -o wide` is a fixed-width table (no JSON form exists). Columns are read from
    the header's offsets so a missing SHORTNAMES cell does not shift the row."""
    lines = [l for l in (text or "").splitlines() if l.strip()]
    if not lines:
        return []
    header = lines[0]
    cols = ["NAME", "SHORTNAMES", "APIVERSION", "NAMESPACED", "KIND", "VERBS", "CATEGORIES"]
    starts = [header.find(c) for c in cols]
    out = []
    for line in lines[1:]:
        cells = []
        for i, start in enumerate(starts):
            if start < 0:
                cells.append("")
                continue
            end = next((s for s in starts[i + 1:] if s >= 0), len(line))
            cells.append(line[start:end].strip() if start < len(line) else "")
        name, short, apiv, namespaced, kind, verbs, cats = cells
        group, _, version = apiv.rpartition("/")
        out.append({
            "name": name, "short_names": [s for s in short.split(",") if s], "api_version": apiv,
            "group": group, "version": version or apiv, "namespaced": namespaced.lower() == "true",
            "kind": kind, "verbs": [v for v in verbs.strip("[]").split(",") if v],
            "categories": [c for c in cats.split(",") if c],
        })
    return out


#: The kinds the inventory's workload summary counts, as kubectl resource names.
WORKLOAD_KINDS = ("deployments", "statefulsets", "daemonsets", "jobs", "cronjobs", "pods")


async def inventory(client, cluster: KubernetesCluster) -> dict[str, Any]:
    """The explorer's opening document. Raises KubectlFailed/AgentClientError when the cluster cannot
    be read — the caller turns that into the named `unreachable` state, never into an empty inventory."""
    version = await probe(client, cluster)
    if not version.get("reachable"):
        raise KubectlFailed("version", 1, version.get("reason") or "unreachable")
    nodes = _items(await call(client, cluster, verb="get", resource="nodes"))
    namespaces = _items(await call(client, cluster, verb="get", resource="namespaces"))
    api_text = (await call(client, cluster, verb="api-resources", output="wide")).get("stdout") or ""
    workloads = _items(await call(client, cluster, verb="get", resource=",".join(WORKLOAD_KINDS), all_namespaces=True))
    try:
        warnings = _items(await call(client, cluster, verb="get", resource="events", all_namespaces=True,
                                     args=["--field-selector", "type=Warning"]))
    except KubectlFailed:
        warnings = []
    # What the Application form offers and checks against: storage classes (with the default), ingress
    # classes (an Ingress without a controller has no effect), quotas per namespace (requests become mandatory).
    try:
        storage_classes = [{"name": (sc.get("metadata") or {}).get("name"), "provisioner": sc.get("provisioner"),
                            "default": ((sc.get("metadata") or {}).get("annotations") or {}).get("storageclass.kubernetes.io/is-default-class") == "true",
                            "binding_mode": sc.get("volumeBindingMode")}
                           for sc in _items(await call(client, cluster, verb="get", resource="storageclasses"))]
    except KubectlFailed:
        storage_classes = []
    try:
        ingress_classes = [(ic.get("metadata") or {}).get("name") for ic in _items(await call(client, cluster, verb="get", resource="ingressclasses"))]
    except KubectlFailed:
        ingress_classes = []
    try:
        quotas = [{"namespace": (q.get("metadata") or {}).get("namespace"), "name": (q.get("metadata") or {}).get("name"),
                   "hard": (q.get("spec") or {}).get("hard") or {}}
                  for q in _items(await call(client, cluster, verb="get", resource="resourcequotas", all_namespaces=True))]
    except KubectlFailed:
        quotas = []

    per_ns: dict[str, dict[str, Any]] = {}
    totals: dict[str, int] = {}
    for obj in workloads:
        kind = obj.get("kind") or "?"
        ns = (obj.get("metadata") or {}).get("namespace") or "-"
        bucket = per_ns.setdefault(ns, {"counts": {}, "unhealthy": 0, "pods": {}})
        bucket["counts"][kind] = bucket["counts"].get(kind, 0) + 1
        totals[kind] = totals.get(kind, 0) + 1
        state = classify(obj)
        if kind == "Pod":
            bucket["pods"][state["state"]] = bucket["pods"].get(state["state"], 0) + 1
        if state["state"] in ("degraded", "failed"):
            bucket["unhealthy"] += 1

    recent_warnings = sorted(
        ({"namespace": (e.get("metadata") or {}).get("namespace"), "reason": e.get("reason"),
          "message": (e.get("message") or "")[:300], "count": e.get("count"),
          "object": f"{(e.get('involvedObject') or {}).get('kind')}/{(e.get('involvedObject') or {}).get('name')}",
          "last_seen": e.get("lastTimestamp") or e.get("eventTime") or (e.get("metadata") or {}).get("creationTimestamp")}
         for e in warnings),
        key=lambda w: w["last_seen"] or "", reverse=True)[:25]

    return {
        "server_version": version.get("server_version"),
        "client_version": version.get("client_version"),
        "server_url": await _server_url(client, cluster),
        "nodes": [summarize_node(n) for n in nodes],
        "namespaces": [summarize_namespace(n) for n in namespaces],
        "api_resources": parse_api_resources(api_text),
        "workloads": {"totals": totals, "by_namespace": per_ns},
        "storage_classes": storage_classes, "ingress_classes": ingress_classes, "quotas": quotas,
        "recent_warnings": recent_warnings,
        "observed_at": datetime.now(timezone.utc).isoformat(),
    }


def apply_inventory(cluster: KubernetesCluster, inv: dict[str, Any], now: datetime) -> None:
    """Write a fresh inventory onto the row: the cache AND the summary columns, in one place."""
    cluster.inventory = inv
    cluster.server_version = inv.get("server_version")
    cluster.server_url = inv.get("server_url") or cluster.server_url
    cluster.node_count = len(inv.get("nodes") or [])
    cluster.namespace_count = len(inv.get("namespaces") or [])
    cluster.reachability = "reachable"
    cluster.unreachable_reason = None
    cluster.observed_at = now
    cluster.updated_at = now


def mark_unreachable(cluster: KubernetesCluster, reason: str, now: datetime) -> None:
    cluster.reachability = "unreachable"
    cluster.unreachable_reason = reason[:500]
    cluster.updated_at = now


async def refresh_inventory(session: AsyncSession, cluster: KubernetesCluster, client, now: datetime) -> dict[str, Any]:
    """Fetch + store. Returns {ok, reason?}. Never raises: an unreachable cluster is a named state."""
    try:
        inv = await inventory(client, cluster)
    except KubectlFailed as exc:
        mark_unreachable(cluster, exc.stderr.strip() or str(exc), now)
        return {"ok": False, "reason": cluster.unreachable_reason}
    except AgentClientError as exc:
        mark_unreachable(cluster, f"access host unreachable: {exc}", now)
        return {"ok": False, "reason": cluster.unreachable_reason}
    apply_inventory(cluster, inv, now)
    return {"ok": True}


async def refresh_inventories_for_agent(session: AsyncSession, agent: Agent, client, now: datetime) -> int:
    """Poller hook: every cluster whose access host is this agent, refreshed when older than
    INVENTORY_MAX_AGE. Returns how many were refreshed."""
    rows = (await session.scalars(select(KubernetesCluster).where(KubernetesCluster.agent_id == agent.id))).all()
    done = 0
    for cluster in rows:
        if cluster.observed_at is not None and (now - cluster.observed_at) < INVENTORY_MAX_AGE \
                and cluster.reachability == "reachable":
            continue
        await refresh_inventory(session, cluster, client, now)
        done += 1
    return done


# ---------------------------------------------------------------------------
# objects: lists, one object, pods, events, logs
# ---------------------------------------------------------------------------

#: Blocking container-waiting reasons: the pod will not become ready by itself.
_WAITING_BLOCKERS = {"ImagePullBackOff", "ErrImagePull", "InvalidImageName", "CreateContainerConfigError",
                     "CreateContainerError", "CrashLoopBackOff", "RunContainerError", "ErrImageNeverPull"}


def _pod_state(pod: dict[str, Any]) -> dict[str, Any]:
    md, st = pod.get("metadata") or {}, pod.get("status") or {}
    if md.get("deletionTimestamp"):
        return _state("terminating", "Terminating", "deletion requested, waiting for containers to stop")
    phase = st.get("phase") or "Unknown"
    statuses = list(st.get("initContainerStatuses") or []) + list(st.get("containerStatuses") or [])
    conds = _conditions(pod)
    if phase == "Succeeded":
        return _state("completed", "Completed", "all containers exited 0")
    if phase == "Failed":
        reason = st.get("reason") or next((((c.get("state") or {}).get("terminated") or {}).get("reason")
                                           for c in statuses if (c.get("state") or {}).get("terminated")), None)
        return _state("failed", reason or "Failed", st.get("message") or "")
    if phase == "Unknown":
        return _state("unknown", st.get("reason") or "Unknown", st.get("message") or "node stopped reporting this pod")
    for c in statuses:
        waiting = (c.get("state") or {}).get("waiting") or {}
        if waiting.get("reason") in _WAITING_BLOCKERS:
            detail = waiting.get("message") or ""
            last = ((c.get("lastState") or {}).get("terminated") or {})
            if waiting["reason"] == "CrashLoopBackOff" and last:
                detail = f"container {c.get('name')} exited {last.get('exitCode')} ({last.get('reason')}), restarts: {c.get('restartCount')}; {detail}"
                if last.get("reason") == "OOMKilled":
                    return _state("degraded", "OOMKilled", detail)
            return _state("degraded", waiting["reason"], f"container {c.get('name')}: {detail}")
    if phase == "Pending":
        sched = conds.get("PodScheduled") or {}
        if sched.get("status") == "False":
            return _state("pending", sched.get("reason") or "Unschedulable", sched.get("message") or "")
        waiting = next((((c.get("state") or {}).get("waiting") or {}) for c in statuses if (c.get("state") or {}).get("waiting")), {})
        return _state("progressing", waiting.get("reason") or "Pending", waiting.get("message") or "containers are being created")
    # Running
    if (conds.get("Ready") or {}).get("status") == "True":
        return _state("healthy", "Running", "all containers ready")
    not_ready = [c.get("name") for c in (st.get("containerStatuses") or []) if not c.get("ready")]
    cr = conds.get("ContainersReady") or {}
    return _state("progressing", cr.get("reason") or "NotReady",
                  cr.get("message") or f"containers not ready: {', '.join(n for n in not_ready if n)}")


def _state(state: str, reason: str | None, detail: str) -> dict[str, Any]:
    assert state in STATES, state
    return {"state": state, "reason": reason, "detail": (detail or "")[:400], "explain": explain(reason)}


def _ratio_state(ready: int, desired: int, obj: dict[str, Any], unit: str = "replicas") -> dict[str, Any]:
    md, st = obj.get("metadata") or {}, obj.get("status") or {}
    if md.get("deletionTimestamp"):
        return _state("terminating", "Terminating", "")
    conds = _conditions(obj)
    if desired == 0:
        return _state("suspended", "ScaledToZero", f"0 {unit} requested")
    stale = (st.get("observedGeneration") or 0) < (md.get("generation") or 0)
    if ready >= desired and not stale:
        return _state("healthy", "Available", f"{ready}/{desired} {unit} ready")
    prog = conds.get("Progressing") or {}
    if prog.get("status") == "False":
        return _state("failed", prog.get("reason") or "ProgressDeadlineExceeded", prog.get("message") or "")
    rf = conds.get("ReplicaFailure") or {}
    if rf.get("status") == "True":
        return _state("degraded", rf.get("reason") or "ReplicaFailure", rf.get("message") or "")
    return _state("progressing", prog.get("reason") or "Progressing", prog.get("message") or f"{ready}/{desired} {unit} ready")


def classify(obj: dict[str, Any]) -> dict[str, Any]:
    """The one state vocabulary (STATES) for any object. Exhaustive by construction: every branch ends in a
    named state, and a kind without runtime status is `static`, not a blank."""
    kind = obj.get("kind") or ""
    md, spec, st = obj.get("metadata") or {}, obj.get("spec") or {}, obj.get("status") or {}
    try:
        if kind == "Pod":
            return _pod_state(obj)
        if kind == "Deployment":
            desired = spec.get("replicas", 1) or 0
            ready = min(st.get("readyReplicas") or 0, st.get("updatedReplicas") or 0)
            if spec.get("paused"):
                return _state("suspended", "Paused", "rollout paused")
            return _ratio_state(ready, desired, obj)
        if kind == "StatefulSet":
            return _ratio_state(st.get("readyReplicas") or 0, spec.get("replicas", 1) or 0, obj)
        if kind == "ReplicaSet":
            return _ratio_state(st.get("readyReplicas") or 0, spec.get("replicas", 1) or 0, obj)
        if kind == "DaemonSet":
            return _ratio_state(st.get("numberReady") or 0, st.get("desiredNumberScheduled") or 0, obj, "pods")
        if kind == "Job":
            conds = _conditions(obj)
            if spec.get("suspend"):
                return _state("suspended", "Suspended", "job suspended")
            if (conds.get("Complete") or {}).get("status") == "True":
                return _state("completed", "Complete", f"{st.get('succeeded', 0)} succeeded")
            if (conds.get("Failed") or {}).get("status") == "True":
                f = conds["Failed"]
                return _state("failed", f.get("reason") or "Failed", f.get("message") or "")
            if st.get("active"):
                return _state("progressing", "Running", f"{st.get('active')} active, {st.get('failed', 0)} failed")
            return _state("pending", "Pending", "no pod started yet")
        if kind == "CronJob":
            if spec.get("suspend"):
                return _state("suspended", "Suspended", "schedule suspended")
            active = len(st.get("active") or [])
            return _state("healthy", "Scheduled", f"schedule {spec.get('schedule')}; {active} active; last {st.get('lastScheduleTime') or 'never'}")
        if kind == "Service":
            if spec.get("type") == "LoadBalancer" and not ((st.get("loadBalancer") or {}).get("ingress")):
                return _state("pending", "LoadBalancerPending", "no external address assigned yet — is there a load-balancer controller?")
            return _state("healthy", "Active", "")
        if kind == "Ingress":
            if not ((st.get("loadBalancer") or {}).get("ingress")):
                return _state("pending", "NoAddress", "no ingress controller has picked this up (check ingressClassName)")
            return _state("healthy", "Active", "")
        if kind == "PersistentVolumeClaim":
            phase = st.get("phase")
            if phase == "Bound":
                return _state("healthy", "Bound", f"volume {spec.get('volumeName')}")
            if phase == "Lost":
                return _state("failed", "Lost", "the bound volume is gone")
            return _state("pending", "Pending", "waiting for a volume (WaitForFirstConsumer, or no provisioner for the class)")
        if kind == "PersistentVolume":
            phase = st.get("phase")
            return {"Bound": _state("healthy", "Bound", ""), "Available": _state("healthy", "Available", "not claimed"),
                    "Released": _state("degraded", "Released", "claim deleted, data retained — reclaim manually"),
                    "Failed": _state("failed", "Failed", st.get("message") or "")}.get(phase, _state("unknown", phase, ""))
        if kind == "Node":
            conds = _conditions(obj)
            if md.get("deletionTimestamp"):
                return _state("terminating", "Terminating", "")
            ready = (conds.get("Ready") or {}).get("status")
            if ready == "False":
                return _state("failed", (conds.get("Ready") or {}).get("reason") or "NotReady", (conds.get("Ready") or {}).get("message") or "")
            if ready != "True":
                return _state("unknown", "Unknown", "kubelet stopped posting status (node-monitor-grace-period elapsed)")
            pressure = [t for t in ("MemoryPressure", "DiskPressure", "PIDPressure", "NetworkUnavailable") if (conds.get(t) or {}).get("status") == "True"]
            if pressure:
                return _state("degraded", pressure[0], ", ".join(pressure))
            if spec.get("unschedulable"):
                return _state("suspended", "Cordoned", "unschedulable: no new pods are placed here")
            return _state("healthy", "Ready", "")
        if kind == "Namespace":
            if st.get("phase") == "Terminating":
                return _state("terminating", "Terminating", "a finalizer may be holding it")
            return _state("healthy", "Active", "")
        if kind == "HorizontalPodAutoscaler":
            conds = _conditions(obj)
            able = conds.get("AbleToScale") or {}
            if able.get("status") == "False":
                return _state("degraded", able.get("reason") or "UnableToScale", able.get("message") or "")
            active = conds.get("ScalingActive") or {}
            if active.get("status") == "False":
                return _state("degraded", active.get("reason") or "ScalingInactive", active.get("message") or "metrics unavailable or no requests set")
            return _state("healthy", "Active", f"{st.get('currentReplicas')} → {st.get('desiredReplicas')} replicas")
        if kind == "Event":
            return _state("static", obj.get("type"), obj.get("reason") or "")
    except (TypeError, ValueError, AttributeError):
        logger.exception("classify failed for %s/%s", kind, md.get("name"))
        return _state("unknown", "ClassifyError", "Bossman could not read this object's status")
    if md.get("deletionTimestamp"):
        return _state("terminating", "Terminating", "")
    return _state("static", None, "this kind carries no runtime status")


def _images(obj: dict[str, Any]) -> list[str]:
    tpl = ((obj.get("spec") or {}).get("template") or {}).get("spec") or (obj.get("spec") or {})
    if obj.get("kind") == "CronJob":
        tpl = ((((obj.get("spec") or {}).get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec") or {}
    return [c.get("image") for c in (tpl.get("containers") or []) if c.get("image")]


def summarize(obj: dict[str, Any]) -> dict[str, Any]:
    """The per-kind columns of a list row — the few facts a table shows, not the object."""
    kind, spec, st = obj.get("kind") or "", obj.get("spec") or {}, obj.get("status") or {}
    s: dict[str, Any] = {}
    if kind in ("Deployment", "StatefulSet", "ReplicaSet"):
        s = {"ready": f"{st.get('readyReplicas', 0)}/{spec.get('replicas', 1)}", "up_to_date": st.get("updatedReplicas", 0),
             "available": st.get("availableReplicas", 0), "images": _images(obj)}
    elif kind == "DaemonSet":
        s = {"ready": f"{st.get('numberReady', 0)}/{st.get('desiredNumberScheduled', 0)}", "images": _images(obj)}
    elif kind == "Job":
        s = {"completions": f"{st.get('succeeded', 0)}/{spec.get('completions', 1)}", "active": st.get("active", 0),
             "failed": st.get("failed", 0), "images": _images(obj)}
    elif kind == "CronJob":
        s = {"schedule": spec.get("schedule"), "suspend": bool(spec.get("suspend")), "active": len(st.get("active") or []),
             "last_schedule": st.get("lastScheduleTime"), "images": _images(obj)}
    elif kind == "Pod":
        cs = st.get("containerStatuses") or []
        s = {"ready": f"{sum(1 for c in cs if c.get('ready'))}/{len(spec.get('containers') or [])}",
             "restarts": sum(c.get("restartCount", 0) for c in cs), "phase": st.get("phase"), "node": spec.get("nodeName"),
             "ip": st.get("podIP"), "images": _images(obj), "qos": st.get("qosClass"),
             "owner": next((f"{o.get('kind')}/{o.get('name')}" for o in ((obj.get("metadata") or {}).get("ownerReferences") or [])), None)}
    elif kind == "Service":
        s = {"type": spec.get("type"), "cluster_ip": spec.get("clusterIP"),
             "ports": [f"{p.get('port')}:{p.get('targetPort')}/{p.get('protocol', 'TCP')}" + (f" (node {p['nodePort']})" if p.get("nodePort") else "") for p in (spec.get("ports") or [])],
             "selector": spec.get("selector") or {}, "external": [i.get("ip") or i.get("hostname") for i in ((st.get("loadBalancer") or {}).get("ingress") or [])]}
    elif kind == "Ingress":
        s = {"class": spec.get("ingressClassName"), "hosts": [r.get("host") for r in (spec.get("rules") or []) if r.get("host")],
             "tls": bool(spec.get("tls")), "address": [i.get("ip") or i.get("hostname") for i in ((st.get("loadBalancer") or {}).get("ingress") or [])]}
    elif kind == "ConfigMap":
        s = {"keys": sorted((obj.get("data") or {}).keys()) + sorted((obj.get("binaryData") or {}).keys()), "immutable": bool(obj.get("immutable"))}
    elif kind == "Secret":
        s = {"type": obj.get("type"), "keys": sorted((obj.get("data") or {}).keys()), "immutable": bool(obj.get("immutable"))}
    elif kind == "PersistentVolumeClaim":
        s = {"phase": st.get("phase"), "volume": spec.get("volumeName"), "capacity": (st.get("capacity") or {}).get("storage"),
             "requested": ((spec.get("resources") or {}).get("requests") or {}).get("storage"),
             "access_modes": spec.get("accessModes"), "storage_class": spec.get("storageClassName")}
    elif kind == "PersistentVolume":
        s = {"phase": st.get("phase"), "capacity": (spec.get("capacity") or {}).get("storage"), "access_modes": spec.get("accessModes"),
             "reclaim": spec.get("persistentVolumeReclaimPolicy"), "storage_class": spec.get("storageClassName"),
             "claim": f"{(spec.get('claimRef') or {}).get('namespace')}/{(spec.get('claimRef') or {}).get('name')}" if spec.get("claimRef") else None}
    elif kind == "StorageClass":
        ann = (obj.get("metadata") or {}).get("annotations") or {}
        s = {"provisioner": obj.get("provisioner"), "reclaim": obj.get("reclaimPolicy"), "binding_mode": obj.get("volumeBindingMode"),
             "expansion": bool(obj.get("allowVolumeExpansion")), "default": ann.get("storageclass.kubernetes.io/is-default-class") == "true"}
    elif kind == "Node":
        s = {k: v for k, v in summarize_node(obj).items() if k not in ("state", "name")}
    elif kind == "Namespace":
        s = {k: v for k, v in summarize_namespace(obj).items() if k not in ("state", "name")}
    elif kind == "HorizontalPodAutoscaler":
        s = {"target": f"{(spec.get('scaleTargetRef') or {}).get('kind')}/{(spec.get('scaleTargetRef') or {}).get('name')}",
             "min": spec.get("minReplicas"), "max": spec.get("maxReplicas"), "current": st.get("currentReplicas"), "desired": st.get("desiredReplicas")}
    elif kind in ("Role", "ClusterRole"):
        s = {"rules": len(obj.get("rules") or [])}
    elif kind in ("RoleBinding", "ClusterRoleBinding"):
        s = {"role": f"{(obj.get('roleRef') or {}).get('kind')}/{(obj.get('roleRef') or {}).get('name')}",
             "subjects": [f"{x.get('kind')}:{x.get('name')}" for x in (obj.get("subjects") or [])]}
    elif kind == "ServiceAccount":
        s = {"automount": obj.get("automountServiceAccountToken", True), "image_pull_secrets": [x.get("name") for x in (obj.get("imagePullSecrets") or [])]}
    elif kind == "NetworkPolicy":
        s = {"pod_selector": (spec.get("podSelector") or {}).get("matchLabels") or {}, "policy_types": spec.get("policyTypes") or []}
    elif kind == "ResourceQuota":
        s = {"hard": st.get("hard") or spec.get("hard") or {}, "used": st.get("used") or {}}
    elif kind == "LimitRange":
        s = {"limits": spec.get("limits") or []}
    elif kind == "PodDisruptionBudget":
        s = {"min_available": spec.get("minAvailable"), "max_unavailable": spec.get("maxUnavailable"),
             "disruptions_allowed": st.get("disruptionsAllowed"), "healthy": f"{st.get('currentHealthy')}/{st.get('expectedPods')}"}
    elif kind == "Event":
        io = obj.get("involvedObject") or {}
        s = {"type": obj.get("type"), "reason": obj.get("reason"), "message": obj.get("message"), "count": obj.get("count"),
             "object": f"{io.get('kind')}/{io.get('name')}", "last_seen": obj.get("lastTimestamp") or obj.get("eventTime")}
    return s


def row(obj: dict[str, Any], now: datetime | None = None) -> dict[str, Any]:
    md = obj.get("metadata") or {}
    return {
        "kind": obj.get("kind"), "api_version": obj.get("apiVersion"),
        "name": md.get("name"), "namespace": md.get("namespace"),
        "labels": md.get("labels") or {}, "age_seconds": _age(md.get("creationTimestamp"), now),
        "state": classify(obj), "summary": summarize(obj),
    }


def _plural_for(cluster: KubernetesCluster, kind: str) -> str:
    for r in (cluster.inventory or {}).get("api_resources") or []:
        if r.get("kind") == kind:
            return r.get("name")
    return kind.lower() + "s"


def etcd_key(cluster: KubernetesCluster, obj: dict[str, Any]) -> str:
    """Where etcd keeps this object (`/registry/<plural>/<namespace>/<name>`) — shown as an explanation of
    where the state lives, never used to read or write it. The layout is the community-documented one;
    kubernetes.io itself does not promise it, and this string is informational."""
    md = obj.get("metadata") or {}
    plural = _plural_for(cluster, obj.get("kind") or "")
    group = (obj.get("apiVersion") or "").split("/")[0] if "/" in (obj.get("apiVersion") or "") else ""
    prefix = f"/registry/{plural}" if group in ("", "apps", "batch", "autoscaling", "policy") else f"/registry/{group}/{plural}"
    return "/".join(p for p in (prefix, md.get("namespace"), md.get("name")) if p)


#: Workload kinds whose list rows are refined by their pods' state (see list_objects).
_POD_OWNING_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"}
_SEVERITY = {"failed": 0, "degraded": 1, "pending": 2, "unknown": 3}


def _matches(selector: dict[str, Any], labels: dict[str, Any]) -> bool:
    ml = selector.get("matchLabels") or {}
    if any(labels.get(k) != v for k, v in ml.items()):
        return False
    for e in selector.get("matchExpressions") or []:
        key, op, vals = e.get("key"), (e.get("operator") or "").lower(), set(e.get("values") or [])
        if op == "in" and labels.get(key) not in vals:
            return False
        if op == "notin" and labels.get(key) in vals:
            return False
        if op == "exists" and key not in labels:
            return False
        if op == "doesnotexist" and key in labels:
            return False
    return True


def refine_with_pods(rows: list[dict[str, Any]], objs: list[dict[str, Any]], pods: list[dict[str, Any]]) -> None:
    """A Deployment stays "Progressing" for progressDeadlineSeconds (10 min by default) while every one of
    its new pods sits in ImagePullBackOff — the controller is honest, but the operator needs the pod's
    reason NOW. So a progressing/pending workload whose selected pods are degraded/failed takes the worst
    pod's state and reason, and says which pod. Healthy workloads are left alone: a stale pod of an old
    ReplicaSet must not paint a finished rollout red."""
    by_ns: dict[str, list[dict[str, Any]]] = {}
    for p in pods:
        by_ns.setdefault((p.get("metadata") or {}).get("namespace") or "", []).append(p)
    for r, o in zip(rows, objs):
        if r["kind"] not in _POD_OWNING_KINDS or r["state"]["state"] not in ("progressing", "pending"):
            continue
        sel = (o.get("spec") or {}).get("selector") or {}
        if not sel:
            continue
        worst = None
        for p in by_ns.get(r.get("namespace") or "", []):
            if not _matches(sel, (p.get("metadata") or {}).get("labels") or {}):
                continue
            st = classify(p)
            if st["state"] in _SEVERITY and (worst is None or _SEVERITY[st["state"]] < _SEVERITY[worst[0]["state"]]):
                worst = (st, (p.get("metadata") or {}).get("name"))
        if worst:
            st, pod_name = worst
            r["state"] = _state(st["state"], st["reason"], f"pod {pod_name}: {st['detail']}"[:400])
            r["state"]["detail"] = f"pod {pod_name}: {st['detail']}"[:400]


async def list_objects(client, cluster: KubernetesCluster, kind: str, namespace: str | None = None,
                       all_namespaces: bool = False, selector: str | None = None) -> dict[str, Any]:
    args = ["-l", selector] if selector else []
    data = await call(client, cluster, verb="get", resource=kind, namespace=namespace,
                      all_namespaces=all_namespaces, args=args)
    now = datetime.now(timezone.utc)
    objs = _items(data)
    rows = [row(o, now) for o in objs]
    if any(r["kind"] in _POD_OWNING_KINDS and r["state"]["state"] in ("progressing", "pending") for r in rows):
        try:
            pods = _items(await call(client, cluster, verb="get", resource="pods", namespace=namespace, all_namespaces=all_namespaces))
        except KubectlFailed:
            pods = []
        refine_with_pods(rows, objs, pods)
    return {"kind": kind, "namespace": None if all_namespaces else namespace, "count": len(rows), "items": rows,
            "warnings": (data.get("stderr") or "").strip() or None}


async def get_object(client, cluster: KubernetesCluster, kind: str, name: str, namespace: str | None = None) -> dict[str, Any]:
    # kubectl hides managedFields unless asked; the field managers are what tells the reader who set what.
    data = await call(client, cluster, verb="get", resource=kind, name=name, namespace=namespace, args=["--show-managed-fields"])
    obj = _parsed(data)
    if not isinstance(obj, dict):
        raise KubectlFailed("get", 1, "object is not a JSON document")
    md = dict(obj.get("metadata") or {})
    managed = md.pop("managedFields", None)
    return {
        "object": obj, "row": row(obj),
        "metadata": md, "spec": obj.get("spec"), "status": obj.get("status"),
        "data_keys": sorted((obj.get("data") or {}).keys()) if isinstance(obj.get("data"), dict) else None,
        "field_managers": sorted({m.get("manager") for m in (managed or []) if m.get("manager")}),
        "versions": {"resource_version": md.get("resourceVersion"), "generation": md.get("generation"),
                     "observed_generation": (obj.get("status") or {}).get("observedGeneration"), "uid": md.get("uid")},
        "etcd_key": etcd_key(cluster, obj),
        "warnings": (data.get("stderr") or "").strip() or None,
    }


def selector_of(obj: dict[str, Any]) -> str | None:
    """The label selector of a workload (matchLabels only; matchExpressions are rendered too)."""
    sel = (obj.get("spec") or {}).get("selector") or {}
    if obj.get("kind") == "Service":
        return ",".join(f"{k}={v}" for k, v in sorted(sel.items())) or None
    parts = [f"{k}={v}" for k, v in sorted((sel.get("matchLabels") or {}).items())]
    for e in sel.get("matchExpressions") or []:
        op = (e.get("operator") or "").lower()
        if op == "in":
            parts.append(f"{e.get('key')} in ({','.join(e.get('values') or [])})")
        elif op == "notin":
            parts.append(f"{e.get('key')} notin ({','.join(e.get('values') or [])})")
        elif op == "exists":
            parts.append(e.get("key"))
        elif op == "doesnotexist":
            parts.append(f"!{e.get('key')}")
    return ",".join(parts) or None


async def pods_for(client, cluster: KubernetesCluster, namespace: str, selector: str) -> dict[str, Any]:
    return await list_objects(client, cluster, "pods", namespace=namespace, selector=selector)


async def events_for(client, cluster: KubernetesCluster, namespace: str | None, name: str | None = None,
                     kind: str | None = None, all_namespaces: bool = False) -> dict[str, Any]:
    fs = []
    if name:
        fs.append(f"involvedObject.name={name}")
    if kind:
        fs.append(f"involvedObject.kind={kind}")
    args = ["--field-selector", ",".join(fs)] if fs else []
    data = await call(client, cluster, verb="get", resource="events", namespace=namespace,
                      all_namespaces=all_namespaces, args=args)
    events = []
    for e in _items(data):
        md = e.get("metadata") or {}
        io = e.get("involvedObject") or {}
        events.append({
            "type": e.get("type"), "reason": e.get("reason"), "message": e.get("message"), "count": e.get("count"),
            "object": f"{io.get('kind')}/{io.get('name')}", "namespace": md.get("namespace"),
            "first_seen": e.get("firstTimestamp") or e.get("eventTime"),
            "last_seen": e.get("lastTimestamp") or e.get("eventTime") or md.get("creationTimestamp"),
            "source": (e.get("source") or {}).get("component") or e.get("reportingComponent"),
            "explain": explain(e.get("reason")) if e.get("type") == "Warning" else None,
        })
    events.sort(key=lambda x: (x["type"] != "Warning", -(_age(x["last_seen"]) or 0) * -1))
    events.sort(key=lambda x: x["last_seen"] or "", reverse=True)
    events.sort(key=lambda x: x["type"] != "Warning")
    return {"count": len(events), "events": events}


async def logs(client, cluster: KubernetesCluster, namespace: str, pod: str, container: str | None = None,
               tail: int = 200, previous: bool = False) -> dict[str, Any]:
    args = ["--tail", str(max(1, min(int(tail), 5000))), "--timestamps"]
    if container:
        args += ["-c", container]
    if previous:
        args.append("--previous")
    try:
        data = await call(client, cluster, verb="logs", resource=f"pod/{pod}", namespace=namespace, output="text", args=args)
    except KubectlFailed as exc:
        return {"pod": pod, "container": container, "previous": previous, "lines": [], "error": exc.stderr.strip()[:500]}
    text = data.get("stdout") or ""
    return {"pod": pod, "container": container, "previous": previous, "tail": tail,
            "lines": text.splitlines(), "truncated": len(text.splitlines()) >= tail}


async def api_resources(client, cluster: KubernetesCluster) -> list[dict[str, Any]]:
    data = await call(client, cluster, verb="api-resources", output="wide")
    return parse_api_resources(data.get("stdout") or "")


async def cluster_or_none(session: AsyncSession, cluster_id: UUID) -> KubernetesCluster | None:
    return await session.get(KubernetesCluster, cluster_id)


# ---------------------------------------------------------------------------
# actions — the operator verbs on a workload or a node (project kubernetes-console, Block 6)
# ---------------------------------------------------------------------------

#: action → (kubectl verb, which kinds it applies to, what it means). Scale and pause/resume are NOT here:
#: they change the object's spec and therefore go through the k8s Resource (generation + approval gate);
#: see api/kubernetes.py. These are kubectl's own imperative verbs — recorded in the agent's operation
#: log and Bossman's audit trail, not as a generation, because they do not change the desired manifest
#: (a restart stamps an annotation; an undo reverts to a revision Kubernetes already holds).
ACTIONS: dict[str, dict[str, Any]] = {
    "restart": {"verb": "rollout restart", "kinds": {"Deployment", "StatefulSet", "DaemonSet"},
                "meaning": "a rolling restart: every pod is replaced, the spec does not change"},
    "undo": {"verb": "rollout undo", "kinds": {"Deployment", "StatefulSet", "DaemonSet"},
             "meaning": "roll back to a previous Kubernetes revision (rollout history), not a Bossman generation"},
    "rollout_status": {"verb": "rollout status", "kinds": {"Deployment", "StatefulSet", "DaemonSet"}, "read": True,
                       "meaning": "is the rollout complete"},
    "rollout_history": {"verb": "rollout history", "kinds": {"Deployment", "StatefulSet", "DaemonSet"}, "read": True,
                        "meaning": "the Kubernetes revisions of this workload"},
    "cordon": {"verb": "cordon", "kinds": {"Node"}, "meaning": "no new pods are scheduled on this node; running pods stay"},
    "uncordon": {"verb": "uncordon", "kinds": {"Node"}, "meaning": "the node accepts new pods again"},
    "drain": {"verb": "drain", "kinds": {"Node"}, "meaning": "cordon, then evict every pod (honouring PodDisruptionBudgets); DaemonSet pods are ignored"},
    "delete_pod": {"verb": "delete", "kinds": {"Pod"}, "meaning": "delete this pod; its controller creates a replacement"},
    "suspend_job": {"verb": "patch", "kinds": {"CronJob"}, "patch": '{"spec":{"suspend":true}}', "meaning": "stop scheduling new jobs"},
    "resume_job": {"verb": "patch", "kinds": {"CronJob"}, "patch": '{"spec":{"suspend":false}}', "meaning": "schedule jobs again"},
}


def action_available(action: str, obj_kind: str, obj: dict[str, Any] | None = None) -> tuple[bool, str]:
    """Whether an action applies to this kind and state — and WHY NOT when it does not (the UI greys the
    button out with this reason instead of letting the click fail)."""
    spec = ACTIONS.get(action)
    if spec is None:
        return False, f"unknown action {action!r}"
    if obj_kind not in spec["kinds"]:
        return False, f"{action} applies to {', '.join(sorted(spec['kinds']))}, not to a {obj_kind}"
    if obj is not None:
        ospec = obj.get("spec") or {}
        if action == "cordon" and ospec.get("unschedulable"):
            return False, "already cordoned"
        if action == "uncordon" and not ospec.get("unschedulable"):
            return False, "not cordoned"
        if action == "suspend_job" and ospec.get("suspend"):
            return False, "already suspended"
        if action == "resume_job" and not ospec.get("suspend"):
            return False, "not suspended"
        if action == "undo" and (obj.get("metadata") or {}).get("deletionTimestamp"):
            return False, "being deleted"
    return True, spec["meaning"]


async def run_action(client, cluster: KubernetesCluster, action: str, kind: str, name: str, namespace: str | None,
                     *, revision: int | None = None, force: bool = False, grace_period: int | None = None) -> dict[str, Any]:
    """Run one imperative action. Returns {ok, action, verb, stdout, stderr, rc}."""
    spec = ACTIONS[action]
    args: list[str] = []
    resource = f"{kind.lower()}/{name}"
    if action == "undo" and revision:
        args.append(f"--to-revision={revision}")
    if action == "drain":
        args += ["--ignore-daemonsets", "--delete-emptydir-data"]
        if force:
            args.append("--force")
        resource = name
    if action in ("cordon", "uncordon"):
        resource = name
    if action == "delete_pod":
        resource = "pod"
        if grace_period is not None:
            args.append(f"--grace-period={int(grace_period)}")
    if spec.get("patch"):
        args += ["--type=merge", "-p", spec["patch"]]
    params: dict[str, Any] = {"verb": spec["verb"], "resource": resource, "args": args, "output": "text"}
    if action == "delete_pod":
        params["name"] = name
        params.pop("output")
    if namespace and kind != "Node":
        params["namespace"] = namespace
    if action == "rollout_history":
        params["output"] = "text"
    try:
        data = await call(client, cluster, **params)
    except KubectlFailed as exc:
        return {"ok": False, "action": action, "verb": spec["verb"], "rc": exc.rc, "stderr": exc.stderr.strip()[:1500], "stdout": ""}
    return {"ok": True, "action": action, "verb": spec["verb"], "rc": data.get("rc"), "stdout": (data.get("stdout") or "").strip()[:4000],
            "stderr": (data.get("stderr") or "").strip()[:1500] or None}


def parse_rollout_history(text: str) -> list[dict[str, Any]]:
    """`kubectl rollout history` → [{revision, change_cause}] (the table has two columns)."""
    out = []
    for line in (text or "").splitlines():
        parts = line.strip().split(None, 1)
        if parts and parts[0].isdigit():
            out.append({"revision": int(parts[0]), "change_cause": (parts[1] if len(parts) > 1 else "").strip() or None})
    return out
