"""The "Application" form → a correct set of Kubernetes manifests (project kubernetes-console, design E6).

Portainer's idea, kept: the operator never picks a kind. They answer "how should it run" (replicated |
on every node | once | on a schedule) and "how is data kept" (none | shared | per instance), and the
form derives the kind — Deployment, DaemonSet, Job, CronJob, or a StatefulSet with volumeClaimTemplates
and the headless Service it needs. The derived kind is SAID, never hidden, so identity holds.

Best practice is the default, not a checklist: the recommended labels are set, the Service selector and
targetPort are generated FROM the workload (the selector-mismatch trap is unreachable), requests/limits
come from a preset, a readiness probe is proposed on the container port, the Restricted Pod Security
profile is on unless switched off, an HPA removes `replicas` from the manifest (or every apply would reset
the count), and `:latest` is warned about rather than blocked. Validation runs against the cluster's
inventory (does the StorageClass exist, is there an IngressClass, does the namespace carry a quota),
before anything is sent — the server-side dry run is the second, authoritative check.

`render()` and `validate()` are pure functions (unit-tested); `plan()`/`apply()` drive the k8s Resource
per object so every write goes through the same four verbs, the same field manager and the same approval
gate as a single object.
"""
from __future__ import annotations

import re
from typing import Any, Literal

from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# the form
# ---------------------------------------------------------------------------

RunMode = Literal["replicated", "every_node", "once", "scheduled"]
DataMode = Literal["none", "shared", "per_instance"]
SecurityProfile = Literal["restricted", "baseline", "privileged"]
ResourcePreset = Literal["small", "medium", "large", "custom", "none"]

PRESETS: dict[str, dict[str, str]] = {
    "small": {"cpu_request": "100m", "memory_request": "128Mi", "cpu_limit": "500m", "memory_limit": "256Mi"},
    "medium": {"cpu_request": "250m", "memory_request": "512Mi", "cpu_limit": "1", "memory_limit": "1Gi"},
    "large": {"cpu_request": "1", "memory_request": "2Gi", "cpu_limit": "2", "memory_limit": "4Gi"},
}


class PortSpec(BaseModel):
    port: int
    name: str = ""
    protocol: Literal["TCP", "UDP", "SCTP"] = "TCP"


class ProbeSpec(BaseModel):
    kind: Literal["none", "http", "tcp", "exec"] = "none"
    path: str = "/"
    port: int | None = None           # None → the first container port
    command: list[str] = []
    initial_delay_seconds: int = 0
    period_seconds: int = 10
    timeout_seconds: int = 1
    failure_threshold: int = 3


class EnvFromSpec(BaseModel):
    kind: Literal["configmap", "secret"]
    name: str
    optional: bool = False


class ConfigMountSpec(BaseModel):
    kind: Literal["configmap", "secret"]
    name: str
    mount_path: str
    read_only: bool = True


class ContainerSpec(BaseModel):
    name: str = ""
    image: str
    ports: list[PortSpec] = []
    command: list[str] = []
    args: list[str] = []
    env: dict[str, str] = {}
    env_from: list[EnvFromSpec] = []
    config_mounts: list[ConfigMountSpec] = []
    preset: ResourcePreset = "small"
    cpu_request: str = ""
    memory_request: str = ""
    cpu_limit: str = ""
    memory_limit: str = ""
    readiness: ProbeSpec = ProbeSpec(kind="http")
    liveness: ProbeSpec = ProbeSpec()
    startup: ProbeSpec = ProbeSpec()
    image_pull_policy: Literal["", "IfNotPresent", "Always", "Never"] = ""
    init: bool = False


class VolumeSpec(BaseModel):
    name: str
    mount_path: str
    size: str = "1Gi"
    storage_class: str = ""          # "" → the cluster's default class
    access_mode: Literal["ReadWriteOnce", "ReadWriteMany", "ReadOnlyMany", "ReadWriteOncePod"] = "ReadWriteOnce"
    existing_claim: str = ""         # reuse a PVC instead of creating one


class EmptyDirSpec(BaseModel):
    name: str
    mount_path: str
    memory: bool = False
    size_limit: str = ""


class ExposeSpec(BaseModel):
    enabled: bool = True
    type: Literal["ClusterIP", "NodePort", "LoadBalancer"] = "ClusterIP"
    port: int | None = None          # service port; None → the container port
    target_port: int | None = None   # None → the first container port
    node_port: int | None = None
    session_affinity: bool = False


class IngressSpec(BaseModel):
    enabled: bool = False
    host: str = ""
    path: str = "/"
    path_type: Literal["Prefix", "Exact", "ImplementationSpecific"] = "Prefix"
    class_name: str = ""
    tls_secret: str = ""


class HpaSpec(BaseModel):
    enabled: bool = False
    min_replicas: int = 1
    max_replicas: int = 3
    cpu_percent: int = 80


class PdbSpec(BaseModel):
    enabled: bool = False
    min_available: str = "50%"


class PlacementSpec(BaseModel):
    node_selector: dict[str, str] = {}
    tolerations: list[dict[str, Any]] = []
    spread_across_nodes: bool = False   # preferred pod anti-affinity on hostname
    required_spread: bool = False       # hard anti-affinity (one per node)


class SecuritySpec(BaseModel):
    profile: SecurityProfile = "restricted"
    run_as_user: int | None = None
    run_as_group: int | None = None
    fs_group: int | None = None
    #: Opt-in, not default: the stock nginx images (even nginx-unprivileged) mkdir under /tmp at start and
    #: exit 1 on a read-only root (measured on minikube: "mkdir() /tmp/proxy_temp failed (30: Read-only
    #: file system)"). Best practice for images that are known not to write; a trap for a first deploy.
    read_only_root_filesystem: bool = False
    service_account: str = ""
    automount_service_account_token: bool | None = None
    image_pull_secret: str = ""


class ScheduleSpec(BaseModel):
    schedule: str = "0 * * * *"
    timezone: str = ""
    concurrency_policy: Literal["Allow", "Forbid", "Replace"] = "Forbid"
    suspend: bool = False
    successful_history: int = 3
    failed_history: int = 1
    backoff_limit: int = 6
    completions: int = 1
    parallelism: int = 1
    ttl_seconds_after_finished: int | None = 3600
    active_deadline_seconds: int | None = None


class RolloutSpec(BaseModel):
    max_surge: str = "25%"
    max_unavailable: str = "25%"
    recreate: bool = False
    min_ready_seconds: int = 0
    revision_history_limit: int = 10
    progress_deadline_seconds: int = 600


class AppForm(BaseModel):
    name: str
    namespace: str = "default"
    description: str = ""
    run_mode: RunMode = "replicated"
    replicas: int = 1
    data_mode: DataMode = "none"
    containers: list[ContainerSpec] = Field(default_factory=list)
    volumes: list[VolumeSpec] = []
    empty_dirs: list[EmptyDirSpec] = []
    expose: ExposeSpec = ExposeSpec()
    ingress: IngressSpec = IngressSpec()
    hpa: HpaSpec = HpaSpec()
    pdb: PdbSpec = PdbSpec()
    rollout: RolloutSpec = RolloutSpec()
    schedule: ScheduleSpec = ScheduleSpec()
    placement: PlacementSpec = PlacementSpec()
    security: SecuritySpec = SecuritySpec()
    labels: dict[str, str] = {}
    annotations: dict[str, str] = {}
    part_of: str = ""
    component: str = ""
    create_namespace: bool = False
    #: An EXISTING workload's selector, carried over when the form re-opens it. A selector is immutable
    #: after creation, so generating the recommended one for an object created with `app: web` would be
    #: refused by the API server — the pods keep matching the labels they always had.
    selector: dict[str, str] = {}


# ---------------------------------------------------------------------------
# derivations
# ---------------------------------------------------------------------------

_DNS_LABEL = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")


def derived_kind(form: AppForm) -> str:
    """The kind the answers imply — and the sentence that says why (the UI shows it next to the form)."""
    if form.run_mode == "every_node":
        return "DaemonSet"
    if form.run_mode == "once":
        return "Job"
    if form.run_mode == "scheduled":
        return "CronJob"
    if form.data_mode == "per_instance":
        return "StatefulSet"
    return "Deployment"


def why_kind(form: AppForm) -> str:
    k = derived_kind(form)
    return {
        "DaemonSet": "one instance on every node → DaemonSet",
        "Job": "runs once to completion → Job",
        "CronJob": "runs on a schedule → CronJob",
        "StatefulSet": "replicated with data kept per instance → StatefulSet with one volume claim per instance and a headless Service",
        "Deployment": "replicated, stateless or with shared data → Deployment",
    }[k]


def image_tag(image: str) -> str | None:
    """`registry/name:tag@digest` → tag (or None when absent). A digest counts as pinned."""
    ref = image.rsplit("/", 1)[-1]
    if "@" in ref:
        return ref.split("@", 1)[1][:19]
    if ":" in ref:
        return ref.split(":", 1)[1]
    return None


def app_labels(form: AppForm) -> dict[str, str]:
    """The recommended labels (kubernetes.io/docs/concepts/overview/working-with-objects/common-labels)."""
    labels = {
        "app.kubernetes.io/name": form.name,
        "app.kubernetes.io/instance": form.name,
        "app.kubernetes.io/managed-by": "bossman",
    }
    tag = image_tag(form.containers[0].image) if form.containers else None
    if tag and not tag.startswith("sha256"):
        labels["app.kubernetes.io/version"] = tag[:63]
    if form.part_of:
        labels["app.kubernetes.io/part-of"] = form.part_of
    if form.component:
        labels["app.kubernetes.io/component"] = form.component
    labels.update(form.labels)
    return labels


def selector_labels(form: AppForm) -> dict[str, str]:
    """The IMMUTABLE selector: only the identity labels, never the version (a version bump must not
    change the selector, which Kubernetes forbids after creation). An existing workload's own selector
    wins — see AppForm.selector."""
    if form.selector:
        return dict(form.selector)
    return {"app.kubernetes.io/name": form.name, "app.kubernetes.io/instance": form.name}


def _resources(c: ContainerSpec) -> dict[str, Any]:
    if c.preset == "none":
        return {}
    vals = dict(PRESETS.get(c.preset, {})) if c.preset != "custom" else {}
    for k in ("cpu_request", "memory_request", "cpu_limit", "memory_limit"):
        if getattr(c, k):
            vals[k] = getattr(c, k)
    req = {k: v for k, v in (("cpu", vals.get("cpu_request")), ("memory", vals.get("memory_request"))) if v}
    lim = {k: v for k, v in (("cpu", vals.get("cpu_limit")), ("memory", vals.get("memory_limit"))) if v}
    out: dict[str, Any] = {}
    if req:
        out["requests"] = req
    if lim:
        out["limits"] = lim
    return out


def _probe(p: ProbeSpec, c: ContainerSpec) -> dict[str, Any] | None:
    if p.kind == "none":
        return None
    port = p.port or (c.ports[0].port if c.ports else None)
    handler: dict[str, Any]
    if p.kind == "http":
        if port is None:
            return None
        handler = {"httpGet": {"path": p.path or "/", "port": port}}
    elif p.kind == "tcp":
        if port is None:
            return None
        handler = {"tcpSocket": {"port": port}}
    else:
        if not p.command:
            return None
        handler = {"exec": {"command": list(p.command)}}
    out = {**handler, "periodSeconds": p.period_seconds, "timeoutSeconds": p.timeout_seconds, "failureThreshold": p.failure_threshold}
    if p.initial_delay_seconds:
        out["initialDelaySeconds"] = p.initial_delay_seconds
    return out


def _container_security(sec: SecuritySpec) -> dict[str, Any]:
    """Exactly the Pod Security Standards (kubernetes.io/docs/concepts/security/pod-security-standards):
    Baseline forbids privilege escalation beyond the default capability set but KEEPS that set — the
    stock nginx image, running as root, needs CHOWN/SETUID/SETGID to drop to its worker user and exits 1
    without them (measured on minikube). Only Restricted drops ALL and demands non-root."""
    if sec.profile == "privileged":
        return {}
    out: dict[str, Any] = {"allowPrivilegeEscalation": False}
    if sec.profile == "restricted":
        out["capabilities"] = {"drop": ["ALL"]}
        out["runAsNonRoot"] = True
        out["seccompProfile"] = {"type": "RuntimeDefault"}
    if sec.read_only_root_filesystem:
        out["readOnlyRootFilesystem"] = True
    if sec.run_as_user is not None:
        out["runAsUser"] = sec.run_as_user
    if sec.run_as_group is not None:
        out["runAsGroup"] = sec.run_as_group
    return out


def _pod_security(sec: SecuritySpec) -> dict[str, Any]:
    out: dict[str, Any] = {}
    if sec.profile == "restricted":
        out["runAsNonRoot"] = True
        out["seccompProfile"] = {"type": "RuntimeDefault"}
    if sec.fs_group is not None:
        out["fsGroup"] = sec.fs_group
    if sec.run_as_user is not None:
        out["runAsUser"] = sec.run_as_user
    return out


def _container(c: ContainerSpec, form: AppForm, index: int) -> dict[str, Any]:
    name = c.name or (form.name if index == 0 else f"{form.name}-{index}")
    out: dict[str, Any] = {"name": name, "image": c.image}
    if c.image_pull_policy:
        out["imagePullPolicy"] = c.image_pull_policy
    if c.command:
        out["command"] = list(c.command)
    if c.args:
        out["args"] = list(c.args)
    if c.ports:
        out["ports"] = [{"containerPort": p.port, "protocol": p.protocol, **({"name": p.name} if p.name else {})} for p in c.ports]
    env = [{"name": k, "value": v} for k, v in c.env.items()]
    if env:
        out["env"] = env
    env_from = [{("configMapRef" if e.kind == "configmap" else "secretRef"): {"name": e.name, **({"optional": True} if e.optional else {})}} for e in c.env_from]
    if env_from:
        out["envFrom"] = env_from
    res = _resources(c)
    if res:
        out["resources"] = res
    if not c.init:
        for key, spec in (("readinessProbe", c.readiness), ("livenessProbe", c.liveness), ("startupProbe", c.startup)):
            pr = _probe(spec, c)
            if pr:
                out[key] = pr
    sc = _container_security(form.security)
    if sc:
        out["securityContext"] = sc
    mounts: list[dict[str, Any]] = []
    for v in form.volumes:
        mounts.append({"name": v.name, "mountPath": v.mount_path})
    for e in form.empty_dirs:
        mounts.append({"name": e.name, "mountPath": e.mount_path})
    for m in c.config_mounts:
        mounts.append({"name": f"{m.kind}-{m.name}", "mountPath": m.mount_path, "readOnly": m.read_only})
    if mounts:
        out["volumeMounts"] = mounts
    return out


def _pod_template(form: AppForm, kind: str) -> dict[str, Any]:
    labels = {**app_labels(form), **selector_labels(form)}   # the template MUST match the selector
    spec: dict[str, Any] = {}
    app_containers = [_container(c, form, i) for i, c in enumerate(form.containers) if not c.init]
    init_containers = [_container(c, form, i) for i, c in enumerate(form.containers) if c.init]
    spec["containers"] = app_containers
    if init_containers:
        spec["initContainers"] = init_containers
    if kind in ("Job", "CronJob"):
        spec["restartPolicy"] = "OnFailure"
    volumes: list[dict[str, Any]] = []
    if kind != "StatefulSet":
        for v in form.volumes:
            volumes.append({"name": v.name, "persistentVolumeClaim": {"claimName": v.existing_claim or f"{form.name}-{v.name}"}})
    for e in form.empty_dirs:
        ed: dict[str, Any] = {}
        if e.memory:
            ed["medium"] = "Memory"
        if e.size_limit:
            ed["sizeLimit"] = e.size_limit
        volumes.append({"name": e.name, "emptyDir": ed})
    seen = set()
    for c in form.containers:
        for m in c.config_mounts:
            vname = f"{m.kind}-{m.name}"
            if vname in seen:
                continue
            seen.add(vname)
            volumes.append({"name": vname, ("configMap" if m.kind == "configmap" else "secret"): ({"name": m.name} if m.kind == "configmap" else {"secretName": m.name})})
    if volumes:
        spec["volumes"] = volumes
    ps = _pod_security(form.security)
    if ps:
        spec["securityContext"] = ps
    if form.security.service_account:
        spec["serviceAccountName"] = form.security.service_account
    if form.security.automount_service_account_token is not None:
        spec["automountServiceAccountToken"] = form.security.automount_service_account_token
    if form.security.image_pull_secret:
        spec["imagePullSecrets"] = [{"name": form.security.image_pull_secret}]
    if form.placement.node_selector:
        spec["nodeSelector"] = dict(form.placement.node_selector)
    if form.placement.tolerations:
        spec["tolerations"] = list(form.placement.tolerations)
    if form.placement.spread_across_nodes or form.placement.required_spread:
        term = {"labelSelector": {"matchLabels": selector_labels(form)}, "topologyKey": "kubernetes.io/hostname"}
        if form.placement.required_spread:
            spec["affinity"] = {"podAntiAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [term]}}
        else:
            spec["affinity"] = {"podAntiAffinity": {"preferredDuringSchedulingIgnoredDuringExecution": [{"weight": 100, "podAffinityTerm": term}]}}
    return {"metadata": {"labels": labels}, "spec": spec}


def _meta(form: AppForm, name: str | None = None, extra_labels: dict[str, str] | None = None) -> dict[str, Any]:
    md: dict[str, Any] = {"name": name or form.name, "namespace": form.namespace, "labels": {**app_labels(form), **(extra_labels or {})}}
    ann = dict(form.annotations)
    if form.description:
        ann["kubernetes.io/description"] = form.description
    if ann:
        md["annotations"] = ann
    return md


def _first_port(form: AppForm) -> int | None:
    for c in form.containers:
        if not c.init and c.ports:
            return c.ports[0].port
    return None


def render(form: AppForm) -> list[dict[str, Any]]:
    """The manifests, in APPLY ORDER (namespace → config → claims → service → workload → ingress → hpa/pdb),
    because the docs say to create a Service before the workloads that use it."""
    kind = derived_kind(form)
    out: list[dict[str, Any]] = []
    if form.create_namespace:
        out.append({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": form.namespace, "labels": {"app.kubernetes.io/managed-by": "bossman"}}})
    if kind != "StatefulSet":
        for v in form.volumes:
            if v.existing_claim:
                continue
            pvc: dict[str, Any] = {"apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": _meta(form, f"{form.name}-{v.name}"),
                                   "spec": {"accessModes": [v.access_mode], "resources": {"requests": {"storage": v.size}}}}
            if v.storage_class:
                pvc["spec"]["storageClassName"] = v.storage_class
            out.append(pvc)
    port = _first_port(form)
    if kind == "StatefulSet":
        # the headless Service a StatefulSet requires, always — not a choice the operator has to know about
        out.append({"apiVersion": "v1", "kind": "Service", "metadata": _meta(form, f"{form.name}-headless"),
                    "spec": {"clusterIP": "None", "selector": selector_labels(form),
                             "ports": [{"name": "main", "port": port or 80, "targetPort": port or 80}]}})
    if form.expose.enabled and port is not None and kind in ("Deployment", "StatefulSet", "DaemonSet"):
        sport = form.expose.port or port
        tport = form.expose.target_port or port
        svc: dict[str, Any] = {"apiVersion": "v1", "kind": "Service", "metadata": _meta(form),
                               "spec": {"type": form.expose.type, "selector": selector_labels(form),
                                        "ports": [{"name": "main", "port": sport, "targetPort": tport, "protocol": "TCP",
                                                   **({"nodePort": form.expose.node_port} if form.expose.node_port and form.expose.type != "ClusterIP" else {})}]}}
        if form.expose.session_affinity:
            svc["spec"]["sessionAffinity"] = "ClientIP"
        out.append(svc)

    template = _pod_template(form, kind)
    sel = {"matchLabels": selector_labels(form)}
    if kind == "Deployment":
        spec: dict[str, Any] = {"selector": sel, "template": template, "revisionHistoryLimit": form.rollout.revision_history_limit,
                                "progressDeadlineSeconds": form.rollout.progress_deadline_seconds}
        if not form.hpa.enabled:
            spec["replicas"] = form.replicas          # with an HPA the autoscaler owns the count
        if form.rollout.recreate:
            spec["strategy"] = {"type": "Recreate"}
        else:
            spec["strategy"] = {"type": "RollingUpdate", "rollingUpdate": {"maxSurge": form.rollout.max_surge, "maxUnavailable": form.rollout.max_unavailable}}
        if form.rollout.min_ready_seconds:
            spec["minReadySeconds"] = form.rollout.min_ready_seconds
        out.append({"apiVersion": "apps/v1", "kind": "Deployment", "metadata": _meta(form), "spec": spec})
    elif kind == "StatefulSet":
        spec = {"serviceName": f"{form.name}-headless", "selector": sel, "template": template, "podManagementPolicy": "OrderedReady",
                "updateStrategy": {"type": "RollingUpdate"}}
        if not form.hpa.enabled:
            spec["replicas"] = form.replicas
        vcts = []
        for v in form.volumes:
            vct: dict[str, Any] = {"metadata": {"name": v.name}, "spec": {"accessModes": [v.access_mode], "resources": {"requests": {"storage": v.size}}}}
            if v.storage_class:
                vct["spec"]["storageClassName"] = v.storage_class
            vcts.append(vct)
        if vcts:
            spec["volumeClaimTemplates"] = vcts
        out.append({"apiVersion": "apps/v1", "kind": "StatefulSet", "metadata": _meta(form), "spec": spec})
    elif kind == "DaemonSet":
        out.append({"apiVersion": "apps/v1", "kind": "DaemonSet", "metadata": _meta(form),
                    "spec": {"selector": sel, "template": template, "updateStrategy": {"type": "RollingUpdate"}}})
    elif kind == "Job":
        js: dict[str, Any] = {"template": template, "backoffLimit": form.schedule.backoff_limit, "completions": form.schedule.completions,
                              "parallelism": form.schedule.parallelism}
        if form.schedule.ttl_seconds_after_finished is not None:
            js["ttlSecondsAfterFinished"] = form.schedule.ttl_seconds_after_finished
        if form.schedule.active_deadline_seconds:
            js["activeDeadlineSeconds"] = form.schedule.active_deadline_seconds
        out.append({"apiVersion": "batch/v1", "kind": "Job", "metadata": _meta(form), "spec": js})
    elif kind == "CronJob":
        js = {"template": template, "backoffLimit": form.schedule.backoff_limit}
        if form.schedule.ttl_seconds_after_finished is not None:
            js["ttlSecondsAfterFinished"] = form.schedule.ttl_seconds_after_finished
        cs: dict[str, Any] = {"schedule": form.schedule.schedule, "concurrencyPolicy": form.schedule.concurrency_policy,
                              "suspend": form.schedule.suspend, "successfulJobsHistoryLimit": form.schedule.successful_history,
                              "failedJobsHistoryLimit": form.schedule.failed_history, "jobTemplate": {"spec": js}}
        if form.schedule.timezone:
            cs["timeZone"] = form.schedule.timezone
        out.append({"apiVersion": "batch/v1", "kind": "CronJob", "metadata": _meta(form), "spec": cs})

    if form.ingress.enabled and form.expose.enabled and port is not None and kind in ("Deployment", "StatefulSet", "DaemonSet"):
        rule: dict[str, Any] = {"http": {"paths": [{"path": form.ingress.path or "/", "pathType": form.ingress.path_type,
                                                    "backend": {"service": {"name": form.name, "port": {"number": form.expose.port or port}}}}]}}
        if form.ingress.host:
            rule["host"] = form.ingress.host
        ispec: dict[str, Any] = {"rules": [rule]}
        if form.ingress.class_name:
            ispec["ingressClassName"] = form.ingress.class_name
        if form.ingress.tls_secret and form.ingress.host:
            ispec["tls"] = [{"hosts": [form.ingress.host], "secretName": form.ingress.tls_secret}]
        out.append({"apiVersion": "networking.k8s.io/v1", "kind": "Ingress", "metadata": _meta(form), "spec": ispec})
    if form.hpa.enabled and kind in ("Deployment", "StatefulSet"):
        out.append({"apiVersion": "autoscaling/v2", "kind": "HorizontalPodAutoscaler", "metadata": _meta(form),
                    "spec": {"scaleTargetRef": {"apiVersion": "apps/v1", "kind": kind, "name": form.name},
                             "minReplicas": form.hpa.min_replicas, "maxReplicas": form.hpa.max_replicas,
                             "metrics": [{"type": "Resource", "resource": {"name": "cpu", "target": {"type": "Utilization", "averageUtilization": form.hpa.cpu_percent}}}]}})
    if form.pdb.enabled and kind in ("Deployment", "StatefulSet"):
        mv: Any = form.pdb.min_available
        if isinstance(mv, str) and mv.isdigit():
            mv = int(mv)
        out.append({"apiVersion": "policy/v1", "kind": "PodDisruptionBudget", "metadata": _meta(form),
                    "spec": {"minAvailable": mv, "selector": sel}})
    return out


# ---------------------------------------------------------------------------
# validation against the form and the cluster's inventory
# ---------------------------------------------------------------------------

def validate(form: AppForm, inventory: dict[str, Any] | None = None) -> list[dict[str, str]]:
    """Issues as {level: error|warning, field, message} — the pre-flight the console shows BEFORE the
    server-side dry run. Errors block Apply; warnings are shown with the reason and do not."""
    inv = inventory or {}
    issues: list[dict[str, str]] = []

    def err(field: str, msg: str) -> None:
        issues.append({"level": "error", "field": field, "message": msg})

    def warn(field: str, msg: str) -> None:
        issues.append({"level": "warning", "field": field, "message": msg})

    if not _DNS_LABEL.match(form.name or "") or len(form.name) > 63:
        err("name", "the name must be a DNS label: lowercase letters, digits and '-', 1–63 characters")
    if derived_kind(form) == "CronJob" and len(form.name) > 52:
        err("name", "a CronJob name must be at most 52 characters (its Job names add 11)")
    if not _DNS_LABEL.match(form.namespace or ""):
        err("namespace", "the namespace must be a DNS label")
    if form.namespace.startswith("kube-"):
        err("namespace", "names starting with kube- are reserved for the system")
    if form.namespace == "default":
        warn("namespace", "the docs advise against running applications in the default namespace — give it its own")
    ns_names = {n.get("name") for n in inv.get("namespaces") or []}
    if ns_names and form.namespace not in ns_names and not form.create_namespace:
        err("namespace", f"namespace {form.namespace!r} does not exist — tick 'create namespace' or pick an existing one")
    if not form.containers:
        err("containers", "at least one container is required")
    for i, c in enumerate(form.containers):
        f = f"containers[{i}]"
        if not c.image.strip():
            err(f"{f}.image", "an image is required")
            continue
        tag = image_tag(c.image)
        if tag is None or tag == "latest":
            warn(f"{f}.image", "no tag or ':latest': the running version is then whatever the node pulls; pin a tag like v1.42.0 or a digest")
        if c.preset == "none":
            warn(f"{f}.preset", "no resource requests: the pod becomes BestEffort (evicted first) and an autoscaler cannot measure it")
        for pname, p in (("readiness", c.readiness), ("liveness", c.liveness), ("startup", c.startup)):
            if p.kind in ("http", "tcp") and not c.ports and p.port is None:
                err(f"{f}.{pname}", f"the {pname} probe needs a container port — add one or set the probe to none")
            if p.kind == "http" and p.port is not None and c.ports and p.port not in {x.port for x in c.ports}:
                err(f"{f}.{pname}", f"the {pname} probe targets port {p.port}, which the container does not declare")
        if c.readiness.kind == "none" and not c.init and derived_kind(form) in ("Deployment", "StatefulSet", "DaemonSet"):
            warn(f"{f}.readiness", "no readiness probe: traffic reaches the pod before it is ready, and a rollout cannot tell a healthy new pod from a broken one")
        for k in c.env:
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k):
                err(f"{f}.env.{k}", f"{k!r} is not a valid environment variable name")
        if c.memory_request and re.match(r"^\d+m$", c.memory_request) or c.memory_limit and re.match(r"^\d+m$", c.memory_limit):
            err(f"{f}.memory", "memory in 'm' means MILLI-BYTES ('400m' = 0.4 bytes) — use Mi or Gi")
    kind = derived_kind(form)
    if kind in ("Deployment", "StatefulSet") and form.replicas < 1 and not form.hpa.enabled:
        warn("replicas", "0 replicas: the application is created but nothing runs")
    if form.hpa.enabled:
        if form.hpa.min_replicas < 1 or form.hpa.max_replicas < form.hpa.min_replicas:
            err("hpa", "autoscaling needs 1 ≤ min ≤ max")
        if any(c.preset == "none" and not c.cpu_request for c in form.containers if not c.init):
            err("hpa", "autoscaling on CPU needs a CPU request on every container (utilization is a percentage of the request)")
    if form.pdb.enabled and kind in ("Deployment", "StatefulSet") and not form.hpa.enabled and form.replicas == 1 and str(form.pdb.min_available) not in ("0", "0%"):
        warn("pdb", "a disruption budget with one replica blocks every node drain — raise the replica count or skip the budget")
    if form.expose.enabled and _first_port(form) is None and kind in ("Deployment", "StatefulSet", "DaemonSet"):
        err("expose", "exposing needs a container port")
    if form.expose.enabled and form.expose.type == "LoadBalancer":
        warn("expose", "LoadBalancer needs a load-balancer controller (cloud, MetalLB, `minikube tunnel`); without one the Service stays pending")
    if form.ingress.enabled:
        if not form.expose.enabled:
            err("ingress", "an Ingress routes to a Service — enable 'expose' first")
        classes = [r for r in inv.get("api_resources") or [] if r.get("kind") == "IngressClass"]
        if inv and not classes:
            warn("ingress", "this cluster serves no IngressClass; without an ingress controller the Ingress has no effect")
        if form.ingress.tls_secret and not form.ingress.host:
            err("ingress", "TLS needs a host name")
    classes = {sc.get("name") for sc in inv.get("storage_classes") or []} if inv.get("storage_classes") else None
    for i, v in enumerate(form.volumes):
        if not _DNS_LABEL.match(v.name):
            err(f"volumes[{i}].name", "a volume name must be a DNS label")
        if not v.mount_path.startswith("/"):
            err(f"volumes[{i}].mount_path", "the mount path must be absolute")
        if classes is not None and v.storage_class and v.storage_class not in classes:
            err(f"volumes[{i}].storage_class", f"StorageClass {v.storage_class!r} does not exist on this cluster")
        if v.access_mode == "ReadWriteOnce" and kind == "Deployment" and (form.replicas > 1 or form.hpa.enabled) and form.data_mode == "shared":
            warn(f"volumes[{i}].access_mode", "ReadWriteOnce attaches to ONE node: several replicas sharing it will not all schedule — use ReadWriteMany or per-instance data")
    if form.data_mode == "shared" and not form.volumes:
        warn("data_mode", "'shared data' selected but no volume defined")
    if form.data_mode == "per_instance" and not form.volumes:
        warn("data_mode", "'per instance data' selected but no volume defined — a StatefulSet without claims")
    quota_ns = {q.get("namespace") for q in inv.get("quotas") or []}
    if form.namespace in quota_ns and any(c.preset == "none" for c in form.containers):
        err("resources", f"namespace {form.namespace!r} has a ResourceQuota: every container must set requests and limits or the pod is rejected")
    if form.security.profile == "privileged":
        warn("security", "privileged: no Pod Security restrictions; a namespace enforcing baseline/restricted will reject these pods")
    enforce = next((n.get("pod_security", {}).get("enforce") for n in inv.get("namespaces") or [] if n.get("name") == form.namespace), None)
    if enforce == "restricted" and form.security.profile != "restricted":
        err("security", "this namespace ENFORCES the restricted Pod Security level — the profile must be restricted")
    if enforce == "baseline" and form.security.profile == "privileged":
        err("security", "this namespace ENFORCES the baseline Pod Security level — privileged pods are rejected")
    if kind == "CronJob" and not re.match(r"^(@(hourly|daily|midnight|weekly|monthly|yearly|annually)|(\S+\s+){4}\S+)$", form.schedule.schedule.strip()):
        err("schedule", "the schedule must be 5 cron fields (minute hour day month weekday) or a macro like @daily")
    return issues


def summary(form: AppForm) -> dict[str, Any]:
    """What the preview says in words — the derived kind and why, the objects that will exist."""
    manifests = render(form)
    return {"kind": derived_kind(form), "why": why_kind(form),
            "objects": [{"kind": m["kind"], "name": m["metadata"]["name"]} for m in manifests]}


# ---------------------------------------------------------------------------
# reverse: an existing application → the form (Portainer's "Edit"), best effort
# ---------------------------------------------------------------------------

def from_objects(workload: dict[str, Any], related: list[dict[str, Any]] | None = None) -> AppForm:
    """Rebuild the form from a live workload (+ its Service/Ingress/HPA/PDB). Fields the form does not
    model are not carried — server-side apply only touches the fields the form sets, so a later apply
    from this form leaves the rest of the object as it is."""
    kind = workload.get("kind")
    md = workload.get("metadata") or {}
    spec = workload.get("spec") or {}
    tpl = (spec.get("template") or {}) if kind != "CronJob" else (((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {})
    pspec = tpl.get("spec") or {}
    name = md.get("name") or ""
    related = related or []
    svc = next((r for r in related if r.get("kind") == "Service" and (r.get("metadata") or {}).get("name") == name), None)
    ing = next((r for r in related if r.get("kind") == "Ingress"), None)
    hpa = next((r for r in related if r.get("kind") == "HorizontalPodAutoscaler"), None)
    pdb = next((r for r in related if r.get("kind") == "PodDisruptionBudget"), None)

    def probe_of(p: dict[str, Any] | None) -> ProbeSpec:
        if not p:
            return ProbeSpec()
        base = {"period_seconds": p.get("periodSeconds", 10), "timeout_seconds": p.get("timeoutSeconds", 1),
                "failure_threshold": p.get("failureThreshold", 3), "initial_delay_seconds": p.get("initialDelaySeconds", 0)}
        if "httpGet" in p:
            return ProbeSpec(kind="http", path=p["httpGet"].get("path", "/"), port=p["httpGet"].get("port") if isinstance(p["httpGet"].get("port"), int) else None, **base)
        if "tcpSocket" in p:
            return ProbeSpec(kind="tcp", port=p["tcpSocket"].get("port") if isinstance(p["tcpSocket"].get("port"), int) else None, **base)
        if "exec" in p:
            return ProbeSpec(kind="exec", command=list(p["exec"].get("command") or []), **base)
        return ProbeSpec()

    containers: list[ContainerSpec] = []
    for init, lst in ((False, pspec.get("containers") or []), (True, pspec.get("initContainers") or [])):
        for c in lst:
            res = c.get("resources") or {}
            req, lim = res.get("requests") or {}, res.get("limits") or {}
            containers.append(ContainerSpec(
                name=c.get("name", ""), image=c.get("image", ""), init=init,
                ports=[PortSpec(port=p.get("containerPort"), name=p.get("name", ""), protocol=p.get("protocol", "TCP")) for p in (c.get("ports") or []) if p.get("containerPort")],
                command=list(c.get("command") or []), args=list(c.get("args") or []),
                env={e["name"]: str(e.get("value", "")) for e in (c.get("env") or []) if e.get("name") and "value" in e},
                env_from=[EnvFromSpec(kind="configmap" if "configMapRef" in e else "secret", name=(e.get("configMapRef") or e.get("secretRef") or {}).get("name", ""))
                          for e in (c.get("envFrom") or []) if (e.get("configMapRef") or e.get("secretRef"))],
                preset="custom" if (req or lim) else "none",
                cpu_request=str(req.get("cpu", "")), memory_request=str(req.get("memory", "")),
                cpu_limit=str(lim.get("cpu", "")), memory_limit=str(lim.get("memory", "")),
                readiness=probe_of(c.get("readinessProbe")) if not init else ProbeSpec(),
                liveness=probe_of(c.get("livenessProbe")), startup=probe_of(c.get("startupProbe")),
                image_pull_policy=c.get("imagePullPolicy", "") or "",
            ))
    run_mode: RunMode = {"DaemonSet": "every_node", "Job": "once", "CronJob": "scheduled"}.get(kind, "replicated")  # type: ignore[assignment]
    sec_c = ((pspec.get("containers") or [{}])[0]).get("securityContext") or {}
    sec_p = pspec.get("securityContext") or {}
    profile: SecurityProfile = "restricted" if (sec_c.get("runAsNonRoot") or sec_p.get("runAsNonRoot")) else ("baseline" if sec_c.get("allowPrivilegeEscalation") is False else "privileged")
    volumes: list[VolumeSpec] = []
    mounts = {m.get("name"): m.get("mountPath") for c in (pspec.get("containers") or []) for m in (c.get("volumeMounts") or [])}
    for v in pspec.get("volumes") or []:
        if v.get("persistentVolumeClaim"):
            volumes.append(VolumeSpec(name=v["name"], mount_path=mounts.get(v["name"], "/data"), existing_claim=v["persistentVolumeClaim"].get("claimName", "")))
    for vct in spec.get("volumeClaimTemplates") or []:
        vm = vct.get("metadata") or {}
        vs = vct.get("spec") or {}
        volumes.append(VolumeSpec(name=vm.get("name", "data"), mount_path=mounts.get(vm.get("name"), "/data"),
                                  size=((vs.get("resources") or {}).get("requests") or {}).get("storage", "1Gi"),
                                  storage_class=vs.get("storageClassName", "") or "", access_mode=(vs.get("accessModes") or ["ReadWriteOnce"])[0]))
    strategy = spec.get("strategy") or {}
    ru = strategy.get("rollingUpdate") or {}
    expose = ExposeSpec(enabled=svc is not None)
    if svc:
        sp = ((svc.get("spec") or {}).get("ports") or [{}])[0]
        expose = ExposeSpec(enabled=True, type=(svc.get("spec") or {}).get("type", "ClusterIP"), port=sp.get("port"),
                            target_port=sp.get("targetPort") if isinstance(sp.get("targetPort"), int) else None,
                            node_port=sp.get("nodePort"), session_affinity=(svc.get("spec") or {}).get("sessionAffinity") == "ClientIP")
    ingress = IngressSpec()
    if ing:
        rule = ((ing.get("spec") or {}).get("rules") or [{}])[0]
        path = ((rule.get("http") or {}).get("paths") or [{}])[0]
        tls = ((ing.get("spec") or {}).get("tls") or [{}])[0]
        ingress = IngressSpec(enabled=True, host=rule.get("host", ""), path=path.get("path", "/"), path_type=path.get("pathType", "Prefix"),
                              class_name=(ing.get("spec") or {}).get("ingressClassName", "") or "", tls_secret=tls.get("secretName", "") or "")
    hpa_spec = HpaSpec()
    if hpa:
        hs = hpa.get("spec") or {}
        m0 = ((hs.get("metrics") or [{}])[0].get("resource") or {}).get("target") or {}
        hpa_spec = HpaSpec(enabled=True, min_replicas=hs.get("minReplicas", 1), max_replicas=hs.get("maxReplicas", 3), cpu_percent=m0.get("averageUtilization", 80))
    pdb_spec = PdbSpec(enabled=pdb is not None, min_available=str(((pdb or {}).get("spec") or {}).get("minAvailable", "50%")))
    sched = ScheduleSpec()
    if kind == "CronJob":
        sched = ScheduleSpec(schedule=spec.get("schedule", "0 * * * *"), timezone=spec.get("timeZone", "") or "", concurrency_policy=spec.get("concurrencyPolicy", "Allow"),
                             suspend=bool(spec.get("suspend")), successful_history=spec.get("successfulJobsHistoryLimit", 3), failed_history=spec.get("failedJobsHistoryLimit", 1))
    elif kind == "Job":
        sched = ScheduleSpec(backoff_limit=spec.get("backoffLimit", 6), completions=spec.get("completions", 1), parallelism=spec.get("parallelism", 1),
                             ttl_seconds_after_finished=spec.get("ttlSecondsAfterFinished"), active_deadline_seconds=spec.get("activeDeadlineSeconds"))
    labels = {k: v for k, v in (md.get("labels") or {}).items() if not k.startswith("app.kubernetes.io/")}
    aff = ((pspec.get("affinity") or {}).get("podAntiAffinity") or {})
    return AppForm(
        name=name, namespace=md.get("namespace", "default"), description=((md.get("annotations") or {}).get("kubernetes.io/description", "")),
        run_mode=run_mode, replicas=spec.get("replicas", 1) if spec.get("replicas") is not None else 1,
        data_mode="per_instance" if kind == "StatefulSet" else ("shared" if volumes else "none"),
        containers=containers, volumes=volumes, expose=expose, ingress=ingress, hpa=hpa_spec, pdb=pdb_spec, schedule=sched,
        rollout=RolloutSpec(max_surge=str(ru.get("maxSurge", "25%")), max_unavailable=str(ru.get("maxUnavailable", "25%")), recreate=strategy.get("type") == "Recreate",
                            min_ready_seconds=spec.get("minReadySeconds", 0), revision_history_limit=spec.get("revisionHistoryLimit", 10),
                            progress_deadline_seconds=spec.get("progressDeadlineSeconds", 600)),
        placement=PlacementSpec(node_selector=dict(pspec.get("nodeSelector") or {}), tolerations=list(pspec.get("tolerations") or []),
                                spread_across_nodes=bool(aff.get("preferredDuringSchedulingIgnoredDuringExecution")),
                                required_spread=bool(aff.get("requiredDuringSchedulingIgnoredDuringExecution"))),
        security=SecuritySpec(profile=profile, run_as_user=sec_p.get("runAsUser"), fs_group=sec_p.get("fsGroup"),
                              read_only_root_filesystem=bool(sec_c.get("readOnlyRootFilesystem")),
                              service_account=pspec.get("serviceAccountName", "") if pspec.get("serviceAccountName") not in (None, "default") else "",
                              image_pull_secret=((pspec.get("imagePullSecrets") or [{}])[0]).get("name", "")),
        labels=labels, annotations={k: v for k, v in (md.get("annotations") or {}).items()
                                    if k not in ("kubernetes.io/description", "deployment.kubernetes.io/revision") and not k.startswith("kubectl.kubernetes.io/")},
        selector=dict(((spec.get("selector") or {}).get("matchLabels") or {})) if kind != "CronJob" else {},
        part_of=(md.get("labels") or {}).get("app.kubernetes.io/part-of", ""), component=(md.get("labels") or {}).get("app.kubernetes.io/component", ""),
    )


# ---------------------------------------------------------------------------
# driving the manifests through the k8s Resource — one object at a time, same verbs, same gate
# ---------------------------------------------------------------------------

def _resource_for(session, agent, client_factory, settings, cluster, manifest: dict[str, Any], requested_by: str | None):
    from bossman.services.resources.kubernetes_object import KubernetesObjectResource

    md = manifest.get("metadata") or {}
    return KubernetesObjectResource(session, agent, client_factory, settings, md.get("name"), cluster=cluster,
                                    namespace=md.get("namespace") or None, api_version=manifest.get("apiVersion") or "v1",
                                    kind=manifest.get("kind") or "ConfigMap", requested_by=requested_by)


_NS_NOT_FOUND = re.compile(r'namespaces? "([^"]+)" not found')


def deferred_by_namespace(reason: str | None, manifests: list[dict[str, Any]]) -> str | None:
    """A server dry run cannot validate an object in a namespace that does not exist yet. When THIS set
    creates that namespace first, the refusal is not a verdict on the object but on the order — so it is
    reported as deferred, by name, instead of as refused. Returns the namespace, or None."""
    m = _NS_NOT_FOUND.search(reason or "")
    if not m:
        return None
    ns = m.group(1)
    created = {x.get("metadata", {}).get("name") for x in manifests if x.get("kind") == "Namespace"}
    return ns if ns in created else None


async def plan_all(session, agent, client_factory, settings, cluster, manifests: list[dict[str, Any]],
                   requested_by: str | None = None) -> list[dict[str, Any]]:
    """Per object: the server-side dry run + diff. Nothing is written. `deferred` names the namespace the
    set creates first, when the server could not validate the object for that reason alone."""
    out = []
    for m in manifests:
        r = _resource_for(session, agent, client_factory, settings, cluster, m, requested_by)
        try:
            plan = await r.plan({"manifest": m})
        except Exception as exc:  # noqa: BLE001 — one object's failure is a row, not the end of the preview
            plan = {"action": "error", "changed_count": 0, "refused": True, "reason": str(exc)[:800]}
        row = {"kind": m["kind"], "name": (m.get("metadata") or {}).get("name"), "namespace": (m.get("metadata") or {}).get("namespace"),
               "action": plan.get("action"), "changed_count": plan.get("changed_count", 0), "refused": bool(plan.get("refused")),
               "reason": plan.get("reason"), "diff_text": plan.get("diff_text"), "server_warnings": plan.get("server_warnings"), "deferred": None}
        if row["refused"]:
            ns = deferred_by_namespace(row["reason"], manifests)
            if ns:
                row.update({"action": "create", "changed_count": 1, "refused": False, "deferred": ns,
                            "reason": f"server validation deferred: namespace {ns!r} is created first in this set"})
        out.append(row)
    return out


async def apply_all(session, agent, client_factory, settings, cluster, manifests: list[dict[str, Any]], *,
                    requested_by: str | None, note: str | None, require_approval: bool) -> dict[str, Any]:
    """Apply in order, stopping at the first failure (what was applied stays applied and is listed, so the
    operator sees exactly how far it got). Outside YOLO mode and without a waiver this files ONE proposal
    carrying every manifest — approving it applies them in the same order."""
    from bossman.services import proposals
    from bossman.services.compiler import is_yolo_mode

    plans = await plan_all(session, agent, client_factory, settings, cluster, manifests, requested_by)
    refused = [p for p in plans if p["refused"]]
    if refused:
        return {"ok": False, "applied": False, "status": "refused", "plans": plans,
                "error": "; ".join(f"{p['kind']}/{p['name']}: {p['reason']}" for p in refused)[:1500]}
    if require_approval and not await is_yolo_mode(session):
        p = await proposals.create_kubernetes_proposal(session, agent, cluster, manifest=manifests[-1], manifests=manifests,
                                                       preview={"plans": plans}, requested_by=requested_by,
                                                       title=f"Application {(manifests[-1].get('metadata') or {}).get('name')} on {cluster.name} ({len(manifests)} objects)")
        return {"ok": True, "applied": False, "status": "pending_approval", "awaiting_approval": True, "proposal_id": str(p.id), "plans": plans}
    results = []
    for m in manifests:
        r = _resource_for(session, agent, client_factory, settings, cluster, m, requested_by)
        res = await r.apply({"manifest": m, "require_approval": False}, dry_run=False, note=note)
        results.append({"kind": m["kind"], "name": (m.get("metadata") or {}).get("name"), "ok": bool(res.get("ok")),
                        "generation": res.get("generation"), "error": res.get("error"), "warnings": res.get("warnings")})
        if not res.get("ok"):
            return {"ok": False, "applied": True, "status": "failed", "plans": plans, "results": results,
                    "error": f"{m['kind']}/{(m.get('metadata') or {}).get('name')}: {res.get('error')}"}
    return {"ok": True, "applied": True, "status": "applied", "awaiting_approval": False, "plans": plans, "results": results}
