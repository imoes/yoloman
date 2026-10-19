"""Kubernetes clusters — registered, inventoried and browsed through their ACCESS HOST
(project kubernetes-console; design in docs/kubernetes-console.md).

A cluster here is an object Bossman knows about: a name, the enrolled agent that holds kubectl and the
kubeconfig, an optional context. Everything else on it is OBSERVED — version, node and namespace counts,
the inventory cache — and carries the time it was observed. Reads go agent → kubectl → API server; this
router never touches etcd and holds no cluster credential.

Named "Kubernetes cluster" everywhere, because a plain "cluster" in this API is the monitoring
HostCluster (`api/clusters.py`), and a Proxmox cluster is a third thing (docs/logik-audit.md).

The four-verb object surface (schema/observe/plan/apply/rollback for ONE object) is deliberately NOT here:
it is the Resource kind `k8s` in services/resources and rides the generic `/agents/{id}/resources/…`
routes with `?cluster=`. This file holds what is outside that contract — the cluster entity and the
non-verb reads (inventory, lists, events, logs).
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.api.auth import get_current_identity, require_manage_kubernetes_cluster
from bossman.api.etag import check_if_match, compute_version
from bossman.api.management import _agent_with_address
from bossman.api.plans import get_client_factory
from bossman.config import Settings, get_settings
from bossman.db.models import Agent, KubernetesCluster
from bossman.db.session import get_session
from bossman.services import kubernetes, kubernetes_app
from bossman.services.kubernetes_app import AppForm
from bossman.services.agent_client import AgentClientError
from bossman.services.auth import user_can_manage_agent
from bossman.services.kubernetes import KubectlFailed

router = APIRouter()


class KubernetesClusterIn(BaseModel):
    name: str
    agent_id: UUID
    context: str | None = None
    kubeconfig_path: str | None = None
    description: str | None = None


class KubernetesClusterOut(BaseModel):
    id: UUID
    name: str
    agent_id: UUID
    agent_name: str | None
    agent_address: str | None
    context: str | None
    kubeconfig_path: str | None
    description: str | None
    server_url: str | None
    server_version: str | None
    node_count: int | None
    namespace_count: int | None
    reachability: str
    unreachable_reason: str | None
    observed_at: datetime | None
    created_at: datetime
    # If-Match tag over the EDITABLE fields only — observed values move on their own and a version that
    # followed them would reject every save (see api/etag.py).
    version: str = ""


def _out(cluster: KubernetesCluster, agent: Agent | None) -> KubernetesClusterOut:
    out = KubernetesClusterOut(
        id=cluster.id, name=cluster.name, agent_id=cluster.agent_id,
        agent_name=agent.name if agent else None, agent_address=agent.address if agent else None,
        context=cluster.context, kubeconfig_path=cluster.kubeconfig_path, description=cluster.description,
        server_url=cluster.server_url, server_version=cluster.server_version,
        node_count=cluster.node_count, namespace_count=cluster.namespace_count,
        reachability=cluster.reachability, unreachable_reason=cluster.unreachable_reason,
        observed_at=cluster.observed_at, created_at=cluster.created_at,
    )
    out.version = compute_version({"name": out.name, "agent_id": str(out.agent_id), "context": out.context,
                                   "kubeconfig_path": out.kubeconfig_path, "description": out.description})
    return out


async def _cluster_or_404(session: AsyncSession, cluster_id: UUID) -> KubernetesCluster:
    cluster = await session.get(KubernetesCluster, cluster_id)
    if cluster is None:
        raise HTTPException(status_code=404, detail=f"no such Kubernetes cluster {cluster_id}")
    return cluster


async def _access(session: AsyncSession, cluster: KubernetesCluster, settings: Settings, client_factory):
    """The cluster's access host, reachable, and a client for it — or the 404/422 the host itself answers."""
    agent = await _agent_with_address(session, cluster.agent_id)
    return agent, client_factory(agent, settings)


def _kubectl_http(exc: Exception) -> HTTPException:
    """kubectl failed (502 with the server's reason) or the host is unreachable (502 with the transport's)."""
    if isinstance(exc, KubectlFailed):
        return HTTPException(status_code=502, detail={"error": "kubectl failed", "verb": exc.verb, "rc": exc.rc,
                                                      "stderr": exc.stderr.strip()[:1000]})
    return HTTPException(status_code=502, detail=str(exc))


async def _validate(body: KubernetesClusterIn, session: AsyncSession, identity, *, cluster_id: UUID | None = None) -> Agent:
    if not body.name.strip():
        raise HTTPException(status_code=422, detail="name is required")
    agent = await session.get(Agent, body.agent_id)
    if agent is None:
        raise HTTPException(status_code=422, detail=f"no such host {body.agent_id} to use as access host")
    if agent.mode == "cluster":
        raise HTTPException(status_code=422, detail="a host cluster cannot be an access host — pick the real host that runs kubectl")
    if not await user_can_manage_agent(session, identity, agent.id):
        raise HTTPException(status_code=403, detail="not authorized to manage the chosen access host")
    dup = await session.scalar(select(KubernetesCluster).where(KubernetesCluster.name == body.name.strip()))
    if dup is not None and dup.id != cluster_id:
        raise HTTPException(status_code=409, detail=f"a Kubernetes cluster named {body.name.strip()!r} already exists")
    return agent


@router.get("/api/v1/kubernetes/clusters", response_model=list[KubernetesClusterOut])
async def list_kubernetes_clusters(
    session: AsyncSession = Depends(get_session),
    _identity=Depends(get_current_identity),
) -> list[KubernetesClusterOut]:
    """Every registered Kubernetes cluster with its access host and last observed facts.

    `reachability` is a named state (reachable | unreachable | never) with `unreachable_reason`, so a cluster
    whose API server is down is listed as such — never silently as empty.
    """
    rows = (await session.scalars(select(KubernetesCluster))).all()
    out = []
    for c in rows:
        out.append(_out(c, await session.get(Agent, c.agent_id)))
    return sorted(out, key=lambda c: c.name)


@router.post("/api/v1/kubernetes/clusters", response_model=KubernetesClusterOut, status_code=201)
async def create_kubernetes_cluster(
    body: KubernetesClusterIn,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    identity=Depends(get_current_identity), client_factory=Depends(get_client_factory),
) -> KubernetesClusterOut:
    """Register a cluster by naming its access host (the enrolled agent that holds kubectl + kubeconfig).

    Bossman stores no credential: the kubeconfig stays on that host. Registration probes the cluster once
    right away, so the answer already says whether it is reachable and which version it runs — or why not.
    """
    agent = await _validate(body, session, identity)
    cluster = KubernetesCluster(name=body.name.strip(), agent_id=agent.id, context=body.context or None,
                                kubeconfig_path=body.kubeconfig_path or None, description=body.description or None)
    session.add(cluster)
    await session.flush()
    now = datetime.now(timezone.utc)
    if agent.address:
        await kubernetes.refresh_inventory(session, cluster, client_factory(agent, settings), now)
    else:
        kubernetes.mark_unreachable(cluster, f"access host {agent.name!r} has no reachable address", now)
    await session.commit()
    return _out(cluster, agent)


@router.get("/api/v1/kubernetes/clusters/{cluster_id}", response_model=KubernetesClusterOut)
async def get_kubernetes_cluster(
    cluster_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(require_manage_kubernetes_cluster),
) -> KubernetesClusterOut:
    """One cluster's registration and last observed facts. Send `version` back as If-Match on PUT."""
    cluster = await _cluster_or_404(session, cluster_id)
    return _out(cluster, await session.get(Agent, cluster.agent_id))


@router.put("/api/v1/kubernetes/clusters/{cluster_id}", response_model=KubernetesClusterOut)
async def update_kubernetes_cluster(
    cluster_id: UUID, body: KubernetesClusterIn, request: Request,
    session: AsyncSession = Depends(get_session), identity=Depends(require_manage_kubernetes_cluster),
) -> KubernetesClusterOut:
    """Change the name, access host, context or kubeconfig path. Honours If-Match (412 when stale).
    Changing the access host resets the observed facts to `never` — they belonged to the old path."""
    cluster = await _cluster_or_404(session, cluster_id)
    current = _out(cluster, await session.get(Agent, cluster.agent_id))
    check_if_match(request, current.version)
    agent = await _validate(body, session, identity, cluster_id=cluster_id)
    moved = agent.id != cluster.agent_id or (body.context or None) != cluster.context or (body.kubeconfig_path or None) != cluster.kubeconfig_path
    cluster.name, cluster.agent_id = body.name.strip(), agent.id
    cluster.context, cluster.kubeconfig_path = body.context or None, body.kubeconfig_path or None
    cluster.description = body.description or None
    cluster.updated_at = datetime.now(timezone.utc)
    if moved:
        cluster.reachability, cluster.unreachable_reason = "never", None
        cluster.inventory, cluster.observed_at = {}, None
        cluster.server_version = cluster.server_url = None
        cluster.node_count = cluster.namespace_count = None
    await session.commit()
    return _out(cluster, agent)


@router.delete("/api/v1/kubernetes/clusters/{cluster_id}", status_code=204)
async def delete_kubernetes_cluster(
    cluster_id: UUID, session: AsyncSession = Depends(get_session), _identity=Depends(require_manage_kubernetes_cluster),
) -> None:
    """Forget the cluster. Nothing on the cluster or the access host is touched — this removes Bossman's
    registration and inventory cache only; the Resource generations of its objects stay in resource_generation."""
    cluster = await _cluster_or_404(session, cluster_id)
    await session.delete(cluster)
    await session.commit()


@router.post("/api/v1/kubernetes/clusters/{cluster_id}/probe")
async def probe_kubernetes_cluster(
    cluster_id: UUID, session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Measure reachability now (`kubectl version` on the access host) and record it. Returns the named
    state and, when unreachable, the reason kubectl gave — the observation point for "is it my kubeconfig?"."""
    cluster = await _cluster_or_404(session, cluster_id)
    agent, client = await _access(session, cluster, settings, client_factory)
    now = datetime.now(timezone.utc)
    try:
        result = await kubernetes.probe(client, cluster)
    except AgentClientError as exc:
        kubernetes.mark_unreachable(cluster, f"access host unreachable: {exc}", now)
        await session.commit()
        return {"reachability": "unreachable", "reason": cluster.unreachable_reason, "access_host": agent.name}
    if result.get("reachable"):
        cluster.reachability, cluster.unreachable_reason = "reachable", None
        cluster.server_version = result.get("server_version")
    else:
        kubernetes.mark_unreachable(cluster, result.get("reason") or "unreachable", now)
    cluster.updated_at = now
    await session.commit()
    return {"reachability": cluster.reachability, "reason": cluster.unreachable_reason,
            "server_version": cluster.server_version, "client_version": result.get("client_version"),
            "access_host": agent.name}


@router.get("/api/v1/kubernetes/clusters/{cluster_id}/inventory")
async def kubernetes_inventory(
    cluster_id: UUID, refresh: bool = False,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """The explorer's opening document: nodes, namespaces, api-resources, a per-namespace workload summary
    and the latest Warning events — served from Bossman's cache (poller-refreshed every 15 min).

    `?refresh=true` fetches live and updates the cache. If the live fetch fails and a cache exists, the cache
    is returned with `stale: true` and the reason; with no cache the answer is 502 with the reason. The
    cache's age is always in the answer (`observed_at`), so the reader knows what they are looking at.
    """
    cluster = await _cluster_or_404(session, cluster_id)
    have_cache = bool(cluster.inventory) and cluster.observed_at is not None
    if not refresh and have_cache:
        return {"cluster_id": str(cluster.id), "inventory": cluster.inventory, "observed_at": cluster.observed_at.isoformat(),
                "reachability": cluster.reachability, "unreachable_reason": cluster.unreachable_reason, "stale": cluster.reachability != "reachable"}
    agent, client = await _access(session, cluster, settings, client_factory)
    now = datetime.now(timezone.utc)
    result = await kubernetes.refresh_inventory(session, cluster, client, now)
    await session.commit()
    if not result.get("ok"):
        if have_cache:
            return {"cluster_id": str(cluster.id), "inventory": cluster.inventory,
                    "observed_at": cluster.observed_at.isoformat() if cluster.observed_at else None,
                    "reachability": cluster.reachability, "unreachable_reason": cluster.unreachable_reason, "stale": True}
        raise HTTPException(status_code=502, detail={"error": "cluster unreachable", "reason": cluster.unreachable_reason, "access_host": agent.name})
    return {"cluster_id": str(cluster.id), "inventory": cluster.inventory, "observed_at": cluster.observed_at.isoformat(),
            "reachability": "reachable", "unreachable_reason": None, "stale": False}


@router.get("/api/v1/kubernetes/clusters/{cluster_id}/api-resources")
async def kubernetes_api_resources(
    cluster_id: UUID, session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Every object kind the API server serves, live (`kubectl api-resources`), including CRDs — the list
    behind the explorer's "All object kinds" node, so nothing the cluster knows is hidden from the console."""
    cluster = await _cluster_or_404(session, cluster_id)
    _agent, client = await _access(session, cluster, settings, client_factory)
    try:
        resources = await kubernetes.api_resources(client, cluster)
    except (KubectlFailed, AgentClientError) as exc:
        raise _kubectl_http(exc) from exc
    return {"cluster_id": str(cluster.id), "count": len(resources), "resources": resources}


@router.get("/api/v1/kubernetes/clusters/{cluster_id}/objects")
async def kubernetes_objects(
    cluster_id: UUID, kind: str = Query(..., description="kubectl resource name or kind, e.g. deployments, pods, svc"),
    namespace: str | None = None, all_namespaces: bool = False, selector: str | None = None,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """List objects of one kind as table rows: name, namespace, age, labels, the per-kind summary columns,
    and the exhaustive `state` (healthy | progressing | degraded | failed | completed | suspended | pending |
    terminating | unknown | static) with the Kubernetes reason and its explanation. Live, not cached."""
    cluster = await _cluster_or_404(session, cluster_id)
    _agent, client = await _access(session, cluster, settings, client_factory)
    try:
        return await kubernetes.list_objects(client, cluster, kind, namespace=namespace, all_namespaces=all_namespaces, selector=selector)
    except (KubectlFailed, AgentClientError) as exc:
        raise _kubectl_http(exc) from exc


@router.get("/api/v1/kubernetes/clusters/{cluster_id}/objects/{kind}/{name}")
async def kubernetes_object(
    cluster_id: UUID, kind: str, name: str, namespace: str | None = None,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """One object, with spec (desired) and status (observed) separated, its versions (resourceVersion,
    generation vs observedGeneration), the field managers that own parts of it, and the etcd key it is
    stored under — shown to explain where the state lives, never used to touch etcd."""
    cluster = await _cluster_or_404(session, cluster_id)
    _agent, client = await _access(session, cluster, settings, client_factory)
    try:
        return await kubernetes.get_object(client, cluster, kind, name, namespace=namespace)
    except KubectlFailed as exc:
        if "NotFound" in exc.stderr or "not found" in exc.stderr:
            raise HTTPException(status_code=404, detail=exc.stderr.strip()[:300]) from exc
        raise _kubectl_http(exc) from exc
    except AgentClientError as exc:
        raise _kubectl_http(exc) from exc


@router.get("/api/v1/kubernetes/clusters/{cluster_id}/pods")
async def kubernetes_pods(
    cluster_id: UUID, namespace: str, selector: str,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """The pods a workload's selector matches — the Pods tab: what IS running for this Deployment, each
    with its state and the reason it is not healthy."""
    cluster = await _cluster_or_404(session, cluster_id)
    _agent, client = await _access(session, cluster, settings, client_factory)
    try:
        return await kubernetes.pods_for(client, cluster, namespace, selector)
    except (KubectlFailed, AgentClientError) as exc:
        raise _kubectl_http(exc) from exc


@router.get("/api/v1/kubernetes/clusters/{cluster_id}/events")
async def kubernetes_events(
    cluster_id: UUID, namespace: str | None = None, name: str | None = None, kind: str | None = None, all_namespaces: bool = False,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Events — the "why" behind a state — for a namespace or one object (`name` + `kind`), Warnings first,
    newest first, each Warning with the reason's explanation. Events are best-effort and short-lived on the
    cluster; an empty list means none are retained, not that nothing happened."""
    cluster = await _cluster_or_404(session, cluster_id)
    _agent, client = await _access(session, cluster, settings, client_factory)
    try:
        return await kubernetes.events_for(client, cluster, namespace, name=name, kind=kind, all_namespaces=all_namespaces)
    except (KubectlFailed, AgentClientError) as exc:
        raise _kubectl_http(exc) from exc


@router.get("/api/v1/kubernetes/clusters/{cluster_id}/logs")
async def kubernetes_logs(
    cluster_id: UUID, namespace: str, pod: str, container: str | None = None, tail: int = 200, previous: bool = False,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """A container's last `tail` log lines (timestamped). `previous=true` reads the crashed predecessor —
    the first thing to open on CrashLoopBackOff. A pod/container kubectl cannot read returns `error`."""
    cluster = await _cluster_or_404(session, cluster_id)
    _agent, client = await _access(session, cluster, settings, client_factory)
    try:
        return await kubernetes.logs(client, cluster, namespace, pod, container=container, tail=tail, previous=previous)
    except AgentClientError as exc:
        raise _kubectl_http(exc) from exc


# ---------------------------------------------------------------------------
# Applications — the click form that becomes a correct set of objects (design E6)
# ---------------------------------------------------------------------------

class AppApplyBody(BaseModel):
    form: AppForm
    dry_run: bool = True
    note: str | None = None
    require_approval: bool = True


async def _inventory_for_validation(session: AsyncSession, cluster: KubernetesCluster, settings: Settings,
                                    client_factory, namespace: str | None) -> dict[str, Any]:
    """The inventory the pre-flight checks run against: the cache — re-read live when the cache does not
    know the form's namespace. The cache is up to 15 minutes old, and "namespace X does not exist" read from a
    cache that predates X is a refusal with a false reason: measured, an application whose namespace Bossman
    had just created could not be edited for a quarter of an hour. A live read that fails keeps the cache."""
    names = {n.get("name") for n in (cluster.inventory or {}).get("namespaces") or []}
    if namespace and names and namespace not in names and cluster.agent_id:
        try:
            _agent, client = await _access(session, cluster, settings, client_factory)
            if (await kubernetes.refresh_inventory(session, cluster, client, datetime.now(timezone.utc))).get("ok"):
                await session.commit()
        except HTTPException:
            pass
    return dict(cluster.inventory or {})


@router.post("/api/v1/kubernetes/clusters/{cluster_id}/applications/render")
async def kubernetes_app_render(
    cluster_id: UUID, form: AppForm, session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """The Application form rendered to manifests — pure, nothing sent to the cluster. Returns the derived
    kind and WHY, the objects in apply order, and the pre-flight issues (errors block, warnings explain)
    checked against the cluster's inventory (namespaces, Pod Security levels, storage classes, quotas)."""
    cluster = await _cluster_or_404(session, cluster_id)
    inv = await _inventory_for_validation(session, cluster, settings, client_factory, form.namespace)
    return {**kubernetes_app.summary(form), "manifests": kubernetes_app.render(form), "issues": kubernetes_app.validate(form, inv)}


@router.post("/api/v1/kubernetes/clusters/{cluster_id}/applications/plan")
async def kubernetes_app_plan(
    cluster_id: UUID, form: AppForm,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """render + the server's verdict per object: `apply --dry-run=server` and the diff, through the same
    k8s Resource a single object uses. Nothing is written. A refusal carries the API server's reason."""
    cluster = await _cluster_or_404(session, cluster_id)
    agent, _client = await _access(session, cluster, settings, client_factory)
    manifests = kubernetes_app.render(form)
    issues = kubernetes_app.validate(form, await _inventory_for_validation(session, cluster, settings, client_factory, form.namespace))
    plans = await kubernetes_app.plan_all(session, agent, client_factory, settings, cluster, manifests, getattr(identity, "name", None))
    return {**kubernetes_app.summary(form), "manifests": manifests, "issues": issues, "plans": plans}


@router.post("/api/v1/kubernetes/clusters/{cluster_id}/applications/apply")
async def kubernetes_app_apply(
    cluster_id: UUID, body: AppApplyBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Apply the application: every object in order (namespace → claims → service → workload → ingress →
    autoscaler/budget), each a server-side apply recorded as a generation. **`dry_run` defaults to true**
    and then answers like /plan. Pre-flight ERRORS refuse with 422 before anything is sent. Outside global
    YOLO mode and without `require_approval: false` the whole set is filed as ONE change proposal and nothing
    is applied; approving it applies the set in the same order."""
    cluster = await _cluster_or_404(session, cluster_id)
    agent, _client = await _access(session, cluster, settings, client_factory)
    manifests = kubernetes_app.render(body.form)
    issues = kubernetes_app.validate(body.form, await _inventory_for_validation(session, cluster, settings, client_factory, body.form.namespace))
    errors = [i for i in issues if i["level"] == "error"]
    if errors:
        raise HTTPException(status_code=422, detail={"error": "the form has errors", "issues": issues})
    who = getattr(identity, "name", None)
    if body.dry_run:
        plans = await kubernetes_app.plan_all(session, agent, client_factory, settings, cluster, manifests, who)
        return {"dry_run": True, **kubernetes_app.summary(body.form), "manifests": manifests, "issues": issues, "plans": plans}
    result = await kubernetes_app.apply_all(session, agent, client_factory, settings, cluster, manifests,
                                            requested_by=who, note=body.note, require_approval=body.require_approval)
    return {"dry_run": False, **kubernetes_app.summary(body.form), "manifests": manifests, "issues": issues, **result}


_WORKLOAD_RESOURCES = ("deployments", "statefulsets", "daemonsets", "cronjobs", "jobs")


@router.get("/api/v1/kubernetes/clusters/{cluster_id}/applications/{namespace}/{name}")
async def kubernetes_app_get(
    cluster_id: UUID, namespace: str, name: str,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """An existing application as the form (Portainer's Edit): the workload of that name (Deployment,
    StatefulSet, DaemonSet, CronJob or Job) plus its Service, Ingress, autoscaler and budget of the same
    name, mapped back best-effort. Fields the form does not model are left on the object by server-side
    apply. 404 when no workload of that name exists."""
    cluster = await _cluster_or_404(session, cluster_id)
    _agent, client = await _access(session, cluster, settings, client_factory)
    workload = None
    for res in _WORKLOAD_RESOURCES:
        try:
            doc = await kubernetes.get_object(client, cluster, res, name, namespace=namespace)
            workload = doc["object"]
            break
        except KubectlFailed as exc:
            if "NotFound" in exc.stderr or "not found" in exc.stderr:
                continue
            raise _kubectl_http(exc) from exc
        except AgentClientError as exc:
            raise _kubectl_http(exc) from exc
    if workload is None:
        raise HTTPException(status_code=404, detail=f"no workload named {name!r} in {namespace!r}")
    related = []
    for res in ("services", "ingresses", "horizontalpodautoscalers", "poddisruptionbudgets"):
        try:
            related.append((await kubernetes.get_object(client, cluster, res, name, namespace=namespace))["object"])
        except (KubectlFailed, AgentClientError):
            continue
    form = kubernetes_app.from_objects(workload, related)
    return {"form": form.model_dump(), "kind": workload.get("kind"), "related": [r.get("kind") for r in related]}


# ---------------------------------------------------------------------------
# Actions — the operator verbs (Block 6)
# ---------------------------------------------------------------------------

class ActionBody(BaseModel):
    action: str
    kind: str
    name: str
    namespace: str | None = None
    #: undo: the Kubernetes revision to return to (0/None = the previous one)
    revision: int | None = None
    #: drain: also evict pods not managed by a controller
    force: bool = False
    #: delete_pod: seconds before SIGKILL (0 = immediately)
    grace_period: int | None = None
    #: scale / pause / resume: the desired value, applied through the k8s Resource (gated, a generation)
    replicas: int | None = None
    require_approval: bool = True
    note: str | None = None


@router.get("/api/v1/kubernetes/clusters/{cluster_id}/actions")
async def kubernetes_actions(
    cluster_id: UUID, kind: str, name: str | None = None, namespace: str | None = None,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    _identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Which actions apply to this object RIGHT NOW, each with the reason when it does not (so the UI greys
    the button out with the reason instead of letting the click fail). Includes the Resource-backed ones
    (scale, pause, resume) and the rollout history for workloads."""
    cluster = await _cluster_or_404(session, cluster_id)
    obj = None
    history: list[dict[str, Any]] = []
    if name:
        _agent, client = await _access(session, cluster, settings, client_factory)
        try:
            obj = (await kubernetes.get_object(client, cluster, kind, name, namespace=namespace))["object"]
        except (KubectlFailed, AgentClientError):
            obj = None
        if obj and obj.get("kind") in ("Deployment", "StatefulSet", "DaemonSet"):
            res = await kubernetes.run_action(client, cluster, "rollout_history", obj["kind"], name, namespace)
            history = kubernetes.parse_rollout_history(res.get("stdout") or "") if res.get("ok") else []
    obj_kind = (obj or {}).get("kind") or kind
    out = []
    for action, spec in kubernetes.ACTIONS.items():
        if spec.get("read"):
            continue
        ok, why = kubernetes.action_available(action, obj_kind, obj)
        # `applies`: the action exists for this KIND at all; `available`: and the current state allows it.
        # The UI hides the first kind of no and greys out the second with its reason.
        out.append({"action": action, "applies": obj_kind in spec["kinds"], "available": ok, "reason": why, "verb": spec["verb"]})
    ospec = (obj or {}).get("spec") or {}
    if obj_kind in ("Deployment", "StatefulSet"):
        out.append({"action": "scale", "applies": True, "available": True, "reason": "set the replica count (a new generation, through the approval gate)", "verb": "apply", "current": ospec.get("replicas")})
    if obj_kind == "Deployment":
        paused = bool(ospec.get("paused"))
        out.append({"action": "pause", "applies": True, "available": not paused, "reason": "already paused" if paused else "record template changes without rolling them out", "verb": "apply"})
        out.append({"action": "resume", "applies": True, "available": paused, "reason": "not paused" if not paused else "roll out the recorded changes", "verb": "apply"})
    return {"kind": obj_kind, "name": name, "namespace": namespace, "actions": out, "rollout_history": history}


@router.post("/api/v1/kubernetes/clusters/{cluster_id}/actions")
async def kubernetes_action(
    cluster_id: UUID, body: ActionBody,
    session: AsyncSession = Depends(get_session), settings: Settings = Depends(get_settings),
    identity=Depends(require_manage_kubernetes_cluster), client_factory=Depends(get_client_factory),
) -> dict[str, Any]:
    """Run one operator action. `scale`, `pause` and `resume` change the desired spec and therefore go through
    the k8s Resource: a server-side apply recorded as a generation, behind the approval gate (a proposal
    outside YOLO mode). The imperative verbs (restart, undo, cordon, uncordon, drain, delete_pod,
    suspend_job, resume_job) run kubectl on the access host and are recorded in the agent's operation log
    and Bossman's audit trail; an unavailable action is refused with the reason, never attempted."""
    cluster = await _cluster_or_404(session, cluster_id)
    agent, client = await _access(session, cluster, settings, client_factory)
    if body.action in ("scale", "pause", "resume"):
        from bossman.services import resources

        api_version = "apps/v1"
        try:
            r = await resources.build("k8s", agent_id=agent.id, name=body.name, session=session, settings=settings,
                                      client_factory=client_factory, identity=identity, cluster=str(cluster.id),
                                      namespace=body.namespace, api_version=api_version, object_kind=body.kind)
        except resources.NoSuchResource as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from None
        if body.action == "scale":
            if body.replicas is None or body.replicas < 0:
                raise HTTPException(status_code=422, detail="scale needs replicas ≥ 0")
            desired: dict[str, Any] = {"replicas": int(body.replicas)}
        else:
            desired = {"paused": body.action == "pause"}
        try:
            res = await r.apply({**desired, "require_approval": body.require_approval}, dry_run=False,
                                note=body.note or (f"scale to {body.replicas}" if body.action == "scale" else body.action))
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from None
        return {"action": body.action, **res}
    try:
        obj = (await kubernetes.get_object(client, cluster, body.kind, body.name, namespace=body.namespace))["object"]
    except KubectlFailed as exc:
        raise HTTPException(status_code=404, detail=exc.stderr.strip()[:300]) from None
    except AgentClientError as exc:
        raise _kubectl_http(exc) from exc
    ok, why = kubernetes.action_available(body.action, obj.get("kind") or body.kind, obj)
    if not ok:
        raise HTTPException(status_code=409, detail={"error": "action not available", "reason": why})
    res = await kubernetes.run_action(client, cluster, body.action, obj.get("kind") or body.kind, body.name, body.namespace,
                                      revision=body.revision, force=body.force, grace_period=body.grace_period)
    return {"action": body.action, "meaning": why, **res}
