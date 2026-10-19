# Kubernetes console — administer a cluster by clicking, with the reason behind every state

> Status: BUILT and verified live (2026-10-09) against minikube v1.35.1 (docker driver) through the running
> Bossman. Blocks 0–6 of the plan are done; Block 7 (Helm in the explorer, SystemMember ↔ cluster) and the
> monitoring checks remain — see "What is still missing". This file is the project document; the plan it
> grew from was the design in `~/.claude/plans/` and is reproduced here with its evidence.

## What it is

A Portainer-simple, Rancher-structured console for a Kubernetes cluster, for an operator who has never
written a manifest. Three screens under **Fleet → Kubernetes clusters**:

1. **The registry** (`/kubernetes`): a cluster is registered by naming its **access host** — the enrolled
   agent that holds `kubectl` and the kubeconfig. Bossman stores no cluster credential and never touches
   etcd. Reachability is a named state (reachable | unreachable | never) with its reason; the observed
   facts (version, nodes, namespaces) carry when they were observed.
2. **The explorer** (`/kubernetes/:id`): source list → list → inspector. Rancher's grouping cut to a
   newcomer's needs (Cluster, Applications, Workloads, Configuration, Network, Storage, Access) plus "All
   object kinds" from `api-resources`, so nothing the API server knows is hidden. Every row carries an
   **exhaustive state** — healthy | progressing | degraded | failed | completed | suspended | pending |
   terminating | unknown | static — with the Kubernetes reason behind it, and the inspector explains the
   reason in plain language with what to do and the kubernetes.io link (`configs/kubernetes_reasons.json`,
   28 reasons). Tabs: State (spec and status apart, generation vs observedGeneration, field managers, the
   etcd key as explanation), Pods (by selector), Events (Warnings first), Logs (container, previous),
   Resource (the generic four-verb inspector), YAML (edit → server dry run + diff → apply). An action bar
   whose buttons are either possible or greyed out with the reason.
3. **The Application form** (`/kubernetes/:id/apps/new`, `…/apps/:ns/:name`): a few answers become a correct
   set of objects. The operator never picks a kind — "how should it run" and "how is data kept" derive
   Deployment | DaemonSet | Job | CronJob | StatefulSet (+ headless Service), and the derived kind is said.
   Best practice is the default: recommended labels, a Service whose selector is generated from the
   workload, a resource preset, a readiness probe, the Restricted Pod Security profile, an HPA that removes
   `replicas`, apply order namespace → claims → service → workload → ingress → autoscaler/budget.

## The decisions, and why

- **Through the access host, not a direct API client.** Every host task is a module (CODE_CARD); the
  kubeconfig stays where it is; mTLS, the write gate, the ACL, the agent's operation log and the audit
  trail apply without a second enforcement path — exactly how the Helm tier already worked.
- **etcd is never read or written.** The docs make the API server the only writer; writing around it skips
  authn/authz, admission, defaulting, validation and resourceVersion bookkeeping. "Show the cluster's
  state as it lives in etcd" therefore means: the object tree in etcd's layout, and the key shown as an
  explanation (`/registry/<plural>/<ns>/<name>`), never as a path to touch.
- **One name for one thing.** "Kubernetes cluster" everywhere (code, API, UI); plain "cluster" is the
  monitoring HostCluster, a Proxmox cluster is a third thing (`docs/logik-audit.md`).
- **Server-side apply with field manager `bossman`, `--validate=strict`.** The fields this console sets are
  visible in `managedFields`; a typo'd key fails instead of being dropped; a foreign manager's field
  conflicts visibly.
- **The preview is the server's verdict.** `apply --dry-run=server` runs admission (Pod Security, quota)
  and validation without persisting; a refusal is shown BEFORE the real apply. When the same set creates the
  namespace first, the dry run of its objects is reported as deferred, by name — not as a verdict.
- **Writes are gated like every other tier.** Outside global YOLO mode and without a waiver, an apply
  files a ChangeProposal (kind `kubernetes`) carrying the preview and records NO generation — a
  never-applied generation would be a false rollback target. An application is ONE proposal with every
  manifest. Rollback and scale go through the same gate; a proposal keeps the note ("rollback to gen 3").
- **Nothing vanishes silently.** Delete previews what goes (ownerReferences) and what stays (PVCs, with the
  reason), then records the deletion as a generation: the object shows as vanished in its history.
- **Two numberings, both labelled.** Bossman's generations (the manifests we applied) and Kubernetes'
  rollout revisions (`rollout history`) are different things and are shown side by side as such.

## What the live run taught (each pinned by a test)

| Lesson | Where it is pinned |
|---|---|
| `kubectl delete -o json` is refused ("We only support '-o name'") | `internal/modules/kubectl_test.go` |
| kubectl hides `managedFields` unless `--show-managed-fields` | `tests/test_resource_k8s.py` (observe argv) |
| A Deployment whose only pod is in ImagePullBackOff lists as "Progressing" for 10 min; the row takes its worst pod's reason | `tests/test_kubernetes_cluster.py::test_a_rolling_workload_takes_its_degraded_pods_reason` |
| The generic Resource inspector rendered the transport envelope as three fields — for every kind | `resource.service.ts` schema() unwrap |
| Baseline per the PSS KEEPS the default capabilities: stock nginx (root) exits 1 without CHOWN/SETUID/SETGID | `tests/test_kubernetes_app.py::test_baseline_keeps_the_default_capabilities` |
| Read-only root filesystem crashes even nginx-unprivileged (`mkdir /tmp/proxy_temp` fails) — opt-in now | `test_kubernetes_app.py` (default off) |
| A workload created with `kubectl create deployment` selects `app: web`; the form must keep that immutable selector | `test_editing_a_foreign_workload_keeps_its_immutable_selector` |
| A server dry run cannot validate an object in a namespace the same set creates first | `test_a_namespace_created_in_the_same_set_defers_the_server_verdict` |

## Where the code is

| Piece | Path |
|---|---|
| Agent module `kubectl` (structured input, read-only map, server-side apply, stdin manifests, rc as data) | `internal/modules/kubectl.go` |
| Cluster entity + migration | `bossman/bossman/db/models.py` (`KubernetesCluster`), `alembic/versions/a9c4e2f7b1d3_*` |
| Service: calls, inventory cache, state vocabulary, lists/object/events/logs, actions | `bossman/bossman/services/kubernetes.py` |
| The Application form → manifests, validation, reverse mapping, plan_all/apply_all | `bossman/bossman/services/kubernetes_app.py` |
| Resource kind `k8s` (four verbs + delete, flat-values inflate, gate) | `bossman/bossman/services/resources/kubernetes_object.py`, registry in `services/resources/__init__.py` |
| REST: clusters, inventory, objects, events, logs, applications, actions | `bossman/bossman/api/kubernetes.py`; verbs under `api/resources.py` (`/agents/{id}/resources/k8s/…?cluster=`) |
| Proposals kind `kubernetes` (one object or a whole application) | `bossman/bossman/services/proposals.py` |
| MCP tools `k8s_*` | `bossman/bossman/mcp/server.py` |
| Reasons table | `configs/kubernetes_reasons.json` |
| UI | `bossman-ui/src/app/features/kubernetes/`, `core/services/kubernetes.service.ts`, `core/services/resource.service.ts` |
| Tests | `bossman/tests/test_kubernetes_cluster.py`, `test_resource_k8s.py`, `test_kubernetes_app.py`, `test_kubernetes_lifecycle_live.py` (integration, skips without a cluster) |

## Verification — the deployment lifecycle on minikube (V1)

`bossman/tests/test_kubernetes_lifecycle_live.py`, run 2026-10-09 against the running stack and
`minikube bossman-dev` (v1.35.1, access host host4.example.internal, agent built from this tree), green in one run:

| # | Step | Measured |
|---|---|---|
| 1–2 | plan by form | Namespace, Service, Deployment; the two namespaced objects "deferred" (namespace created first); no errors |
| 3 | apply (waived) | three generations 1; Deployment healthy 1/1; pod Burstable; Service selector = identity labels |
| 4 | scale to 3 by form | 3/3 healthy |
| 5 | image 1.27 → 1.28 | the diff names only the image; rollout; generations 3, 2, 1 with notes |
| 6 | image `nginx:doesnotexist` | row degraded with the pod's reason (ImagePullBackOff/ErrImagePull), explanation and fix; Warning event |
| 7 | rollback to gen 3 | filed as a proposal (YOLO off) → approved → generation 5 on 1.28, 3/3 healthy; field manager `bossman`; etcd key |
| 8 | logs | timestamped nginx lines |
| 9 | edit | the live application re-opened as the form (replicas 3, image 1.28, Service related) |
| 10 | delete | preview names ReplicaSet + Pods; delete → generation 6 `deleted: true`; observe → none |
| 11 | history | the deletion is the newest generation — nothing vanished silently |
| 12 | namespace | deleted and gone |

Also verified in the browser (Playwright): registry, Overview, Pods list with the broken pod Degraded, the
inspector's why-box, Events, Pods tab by selector, Resource tab with 12 typed fields, the wizard rendering
objects + checks + YAML and filing a proposal, the action bar and the delete preview — zero console errors.

Actions verified through the API: restart, gated scale → proposal → 2/2, waived scale → generation 4,
rollout history 1–3, undo, cordon → "already cordoned" (409) → uncordon, restart on a ConfigMap refused
with the kinds it applies to.

## What is still missing

- **Helm inside the explorer** (Block 7): the "Helm releases" node links to the access host's Kubernetes
  tab; releases are not yet listed in the explorer itself. `SystemMember.target = k8s` does not reference
  a `KubernetesCluster` yet, and clone/rehearse/promote still skip k8s members.
- **Monitoring**: no `kube_*` checks are translated (28 Checkmk sections are catalogued); pod/workload states
  do not appear in Problems yet.
- **The fleet's second cluster**: the plan named the fleet host `minikube` behind `docker-test` as the
  second verification target; its agent port was unreachable during this work, so only the local minikube
  is proven.
- **Form coverage**: the generic Values tab derives one field per spec value but skips lists of objects
  (containers); container edits go through the Application form or the YAML tab. Tolerations, extra
  volumes beyond PVC/emptyDir and ConfigMap/Secret authoring are YAML-only.
- **Watch**: lists are read on demand (and the inventory cached 15 min); there is no live watch stream.
- **The kubeconfig template** in the mined catalog targets `/etc/kubectl`, a path that does not exist; a
  kubeconfig is per user. The catalog is generated by the qualify pipeline, so the fix belongs there.
