"""The Application form → manifests (services/kubernetes_app): pure, so every rule is pinned offline."""
from __future__ import annotations

import json

from bossman.services import kubernetes_app as ka
from bossman.services.kubernetes_app import AppForm, ContainerSpec, PortSpec, VolumeSpec


def _form(**over):
    base = dict(name="web", namespace="shop", containers=[ContainerSpec(image="nginx:1.27", ports=[PortSpec(port=80)])])
    base.update(over)
    return AppForm(**base)


def _by_kind(manifests, kind):
    return next(m for m in manifests if m["kind"] == kind)


def test_the_simple_case_is_a_deployment_plus_service_with_best_practice_defaults():
    ms = ka.render(_form())
    assert [m["kind"] for m in ms] == ["Service", "Deployment"]          # service before the workload (the docs' order)
    dep, svc = _by_kind(ms, "Deployment"), _by_kind(ms, "Service")
    labels = dep["metadata"]["labels"]
    assert labels["app.kubernetes.io/name"] == "web" and labels["app.kubernetes.io/managed-by"] == "bossman" and labels["app.kubernetes.io/version"] == "1.27"
    # the selector is the identity labels only — never the version, which may change
    assert dep["spec"]["selector"]["matchLabels"] == {"app.kubernetes.io/name": "web", "app.kubernetes.io/instance": "web"}
    assert svc["spec"]["selector"] == dep["spec"]["selector"]["matchLabels"]      # selector mismatch is unreachable
    assert svc["spec"]["ports"][0] == {"name": "main", "port": 80, "targetPort": 80, "protocol": "TCP"}
    c = dep["spec"]["template"]["spec"]["containers"][0]
    assert c["resources"] == {"requests": {"cpu": "100m", "memory": "128Mi"}, "limits": {"cpu": "500m", "memory": "256Mi"}}
    assert c["readinessProbe"]["httpGet"] == {"path": "/", "port": 80}
    assert c["securityContext"] == {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}, "runAsNonRoot": True,
                                    "seccompProfile": {"type": "RuntimeDefault"}}
    ro = _by_kind(ka.render(_form(security=ka.SecuritySpec(read_only_root_filesystem=True))), "Deployment")
    assert ro["spec"]["template"]["spec"]["containers"][0]["securityContext"]["readOnlyRootFilesystem"] is True
    assert dep["spec"]["template"]["spec"]["securityContext"] == {"runAsNonRoot": True, "seccompProfile": {"type": "RuntimeDefault"}}
    assert dep["spec"]["replicas"] == 1 and dep["spec"]["strategy"]["rollingUpdate"] == {"maxSurge": "25%", "maxUnavailable": "25%"}
    assert ka.why_kind(_form()).endswith("→ Deployment")


def test_baseline_keeps_the_default_capabilities():
    """The stock nginx image runs as root and needs CHOWN/SETUID/SETGID; Baseline (per the PSS) keeps the
    default set and only forbids escalation. Restricted is the one that drops ALL."""
    base = _form(security=ka.SecuritySpec(profile="baseline", read_only_root_filesystem=False))
    c = _by_kind(ka.render(base), "Deployment")["spec"]["template"]["spec"]["containers"][0]
    assert c["securityContext"] == {"allowPrivilegeEscalation": False}
    assert "securityContext" not in _by_kind(ka.render(base), "Deployment")["spec"]["template"]["spec"]
    priv = _form(security=ka.SecuritySpec(profile="privileged"))
    assert "securityContext" not in _by_kind(ka.render(priv), "Deployment")["spec"]["template"]["spec"]["containers"][0]


def test_the_kind_follows_the_answers_and_is_said():
    assert ka.derived_kind(_form(run_mode="every_node")) == "DaemonSet"
    assert ka.derived_kind(_form(run_mode="once")) == "Job"
    assert ka.derived_kind(_form(run_mode="scheduled")) == "CronJob"
    assert ka.derived_kind(_form(data_mode="per_instance")) == "StatefulSet"
    sts = ka.render(_form(data_mode="per_instance", volumes=[VolumeSpec(name="data", mount_path="/var/lib/data", size="5Gi")]))
    kinds = [m["kind"] for m in sts]
    assert kinds == ["Service", "Service", "StatefulSet"]                      # headless + exposed
    headless = sts[0]
    assert headless["spec"]["clusterIP"] == "None" and headless["metadata"]["name"] == "web-headless"
    s = _by_kind(sts, "StatefulSet")
    assert s["spec"]["serviceName"] == "web-headless"
    assert s["spec"]["volumeClaimTemplates"][0]["spec"]["resources"]["requests"]["storage"] == "5Gi"
    assert "persistentVolumeClaim" not in json.dumps(s["spec"]["template"])    # claims come from the template, not a shared PVC
    assert s["spec"]["template"]["spec"]["containers"][0]["volumeMounts"] == [{"name": "data", "mountPath": "/var/lib/data"}]
    cron = ka.render(_form(run_mode="scheduled"))
    assert [m["kind"] for m in cron] == ["CronJob"]                              # no Service for a job
    cj = cron[0]["spec"]
    assert cj["schedule"] == "0 * * * *" and cj["concurrencyPolicy"] == "Forbid" and cj["jobTemplate"]["spec"]["template"]["spec"]["restartPolicy"] == "OnFailure"
    job = ka.render(_form(run_mode="once"))[0]
    assert job["spec"]["ttlSecondsAfterFinished"] == 3600 and job["spec"]["backoffLimit"] == 6


def test_shared_data_makes_a_pvc_and_hpa_drops_replicas():
    ms = ka.render(_form(data_mode="shared", volumes=[VolumeSpec(name="uploads", mount_path="/srv/uploads", size="10Gi", storage_class="fast", access_mode="ReadWriteMany")]))
    assert [m["kind"] for m in ms] == ["PersistentVolumeClaim", "Service", "Deployment"]
    pvc = ms[0]
    assert pvc["metadata"]["name"] == "web-uploads" and pvc["spec"]["storageClassName"] == "fast" and pvc["spec"]["accessModes"] == ["ReadWriteMany"]
    dep = _by_kind(ms, "Deployment")
    assert dep["spec"]["template"]["spec"]["volumes"] == [{"name": "uploads", "persistentVolumeClaim": {"claimName": "web-uploads"}}]
    ms = ka.render(_form(hpa=ka.HpaSpec(enabled=True, min_replicas=2, max_replicas=5, cpu_percent=70), pdb=ka.PdbSpec(enabled=True, min_available="1")))
    dep = _by_kind(ms, "Deployment")
    assert "replicas" not in dep["spec"]                                         # the autoscaler owns the count
    hpa = _by_kind(ms, "HorizontalPodAutoscaler")
    assert hpa["spec"]["scaleTargetRef"] == {"apiVersion": "apps/v1", "kind": "Deployment", "name": "web"} and hpa["spec"]["maxReplicas"] == 5
    assert _by_kind(ms, "PodDisruptionBudget")["spec"]["minAvailable"] == 1


def test_ingress_and_placement_and_env():
    f = _form(ingress=ka.IngressSpec(enabled=True, host="shop.example.com", class_name="nginx", tls_secret="shop-tls"),
              placement=ka.PlacementSpec(required_spread=True, node_selector={"disk": "ssd"}),
              containers=[ContainerSpec(image="nginx:1.27", ports=[PortSpec(port=8080, name="http")], env={"LOG_LEVEL": "info"},
                                        env_from=[ka.EnvFromSpec(kind="secret", name="web-secrets")],
                                        config_mounts=[ka.ConfigMountSpec(kind="configmap", name="web-config", mount_path="/etc/web")])])
    ms = ka.render(f)
    ing = _by_kind(ms, "Ingress")
    assert ing["spec"]["ingressClassName"] == "nginx" and ing["spec"]["tls"] == [{"hosts": ["shop.example.com"], "secretName": "shop-tls"}]
    assert ing["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"] == {"name": "web", "port": {"number": 8080}}
    ps = _by_kind(ms, "Deployment")["spec"]["template"]["spec"]
    assert ps["nodeSelector"] == {"disk": "ssd"}
    assert ps["affinity"]["podAntiAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"][0]["topologyKey"] == "kubernetes.io/hostname"
    c = ps["containers"][0]
    assert c["env"] == [{"name": "LOG_LEVEL", "value": "info"}] and c["envFrom"] == [{"secretRef": {"name": "web-secrets"}}]
    assert c["volumeMounts"] == [{"name": "configmap-web-config", "mountPath": "/etc/web", "readOnly": True}]
    assert ps["volumes"] == [{"name": "configmap-web-config", "configMap": {"name": "web-config"}}]


def test_validation_names_the_rule_behind_each_issue():
    inv = {"namespaces": [{"name": "shop", "pod_security": {"enforce": "restricted"}}, {"name": "default", "pod_security": {}}],
           "storage_classes": [{"name": "standard"}], "api_resources": [{"kind": "Deployment"}], "quotas": [{"namespace": "shop"}]}
    f = _form(containers=[ContainerSpec(image="nginx", preset="none", readiness=ka.ProbeSpec(kind="none"))],
              volumes=[VolumeSpec(name="d", mount_path="relative", storage_class="nope")],
              security=ka.SecuritySpec(profile="privileged"), ingress=ka.IngressSpec(enabled=True), expose=ka.ExposeSpec(enabled=False))
    issues = {(i["field"], i["level"]) for i in ka.validate(f, inv)}
    assert ("containers[0].image", "warning") in issues         # no tag
    assert ("containers[0].preset", "warning") in issues        # BestEffort
    assert ("containers[0].readiness", "warning") in issues
    assert ("volumes[0].mount_path", "error") in issues and ("volumes[0].storage_class", "error") in issues
    assert ("ingress", "error") in issues                       # ingress without expose
    assert ("ingress", "warning") in issues                     # no IngressClass on this cluster
    assert ("resources", "error") in issues                     # quota demands requests
    assert ("security", "error") in issues                      # namespace enforces restricted
    assert not [i for i in ka.validate(_form(), {"namespaces": [{"name": "shop"}]}) if i["level"] == "error"]
    bad = ka.validate(_form(name="Web_1"), {})
    assert any(i["field"] == "name" and i["level"] == "error" for i in bad)
    m = ka.validate(_form(containers=[ContainerSpec(image="x:1", preset="custom", memory_limit="400m")]), {})
    assert any("MILLI-BYTES" in i["message"] for i in m)
    assert any(i["field"] == "namespace" and "does not exist" in i["message"] for i in ka.validate(_form(namespace="new"), {"namespaces": [{"name": "shop"}]}))
    assert not any(i["field"] == "namespace" and i["level"] == "error" for i in ka.validate(_form(namespace="new", create_namespace=True), {"namespaces": [{"name": "shop"}]}))


def test_round_trip_through_from_objects():
    f = _form(replicas=3, hpa=ka.HpaSpec(enabled=False), ingress=ka.IngressSpec(enabled=True, host="h.example.com"),
              containers=[ContainerSpec(image="nginx:1.27", ports=[PortSpec(port=80)], env={"A": "1"}, preset="medium")],
              placement=ka.PlacementSpec(spread_across_nodes=True), description="the shop front")
    ms = ka.render(f)
    back = ka.from_objects(_by_kind(ms, "Deployment"), [m for m in ms if m["kind"] != "Deployment"])
    assert back.name == "web" and back.namespace == "shop" and back.replicas == 3 and back.description == "the shop front"
    assert back.containers[0].image == "nginx:1.27" and back.containers[0].env == {"A": "1"} and back.containers[0].cpu_request == "250m"
    assert back.containers[0].readiness.kind == "http" and back.containers[0].readiness.port == 80
    assert back.expose.enabled and back.expose.port == 80 and back.ingress.enabled and back.ingress.host == "h.example.com"
    assert back.security.profile == "restricted" and not back.security.read_only_root_filesystem and back.placement.spread_across_nodes
    # rendering the rebuilt form reproduces the workload's spec
    again = _by_kind(ka.render(back), "Deployment")
    assert again["spec"]["template"]["spec"]["containers"][0] == _by_kind(ms, "Deployment")["spec"]["template"]["spec"]["containers"][0]


def test_a_namespace_created_in_the_same_set_defers_the_server_verdict():
    ms = ka.render(_form(create_namespace=True))
    assert ka.deferred_by_namespace('Error from server (NotFound): namespaces "shop" not found', ms) == "shop"
    assert ka.deferred_by_namespace('Error from server (NotFound): namespaces "other" not found', ms) is None
    assert ka.deferred_by_namespace('admission webhook denied', ms) is None
    assert ka.deferred_by_namespace('namespaces "shop" not found', ka.render(_form())) is None   # not created by this set


def test_editing_a_foreign_workload_keeps_its_immutable_selector():
    """A Deployment created with `kubectl create deployment` selects `app: web`. Re-opened as the form and
    rendered again, the selector must be the SAME — the API server refuses a changed selector — and the
    pod template must carry it, or the Deployment would select nothing."""
    foreign = {"apiVersion": "apps/v1", "kind": "Deployment",
               "metadata": {"name": "web", "namespace": "ui-check", "labels": {"app": "web"},
                            "annotations": {"kubectl.kubernetes.io/last-applied-configuration": "{...}", "deployment.kubernetes.io/revision": "1"}},
               "spec": {"replicas": 1, "selector": {"matchLabels": {"app": "web"}},
                        "template": {"metadata": {"labels": {"app": "web"}}, "spec": {"containers": [{"name": "nginx", "image": "nginx:1.27", "ports": [{"containerPort": 80}]}]}}}}
    form = ka.from_objects(foreign, [])
    assert form.selector == {"app": "web"} and form.labels == {"app": "web"} and form.annotations == {}
    dep = _by_kind(ka.render(form), "Deployment")
    assert dep["spec"]["selector"]["matchLabels"] == {"app": "web"}
    tpl_labels = dep["spec"]["template"]["metadata"]["labels"]
    assert tpl_labels["app"] == "web" and tpl_labels["app.kubernetes.io/name"] == "web"
    svc = _by_kind(ka.render(ka.AppForm(**{**form.model_dump(), "expose": ka.ExposeSpec(enabled=True)})), "Service")
    assert svc["spec"]["selector"] == {"app": "web"}
