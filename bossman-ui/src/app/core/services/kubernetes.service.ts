import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders, HttpParams } from '@angular/common/http';
import { environment } from '../../../environments/environment';

/**
 * Kubernetes clusters (API: /api/v1/kubernetes/clusters, services/kubernetes.py).
 *
 * A cluster is registered by naming its ACCESS HOST — the enrolled agent that holds kubectl and the
 * kubeconfig. Bossman stores no credential and never touches etcd; every read here is agent → kubectl →
 * API server. Called "Kubernetes cluster" throughout: a bare "cluster" in this app is the monitoring host
 * cluster, and a Proxmox cluster is a third thing.
 */

export type Reachability = 'reachable' | 'unreachable' | 'never';

export interface KubernetesCluster {
  id: string;
  name: string;
  agent_id: string;
  agent_name: string | null;
  agent_address: string | null;
  context: string | null;
  kubeconfig_path: string | null;
  description: string | null;
  server_url: string | null;
  server_version: string | null;
  node_count: number | null;
  namespace_count: number | null;
  /** A named state with its reason — an unreachable cluster is shown as such, never as empty. */
  reachability: Reachability;
  unreachable_reason: string | null;
  observed_at: string | null;
  created_at: string;
  /** Send back as If-Match on PUT (api/etag.py). */
  version: string;
}

export interface KubernetesClusterInput {
  name: string;
  agent_id: string;
  context?: string | null;
  kubeconfig_path?: string | null;
  description?: string | null;
}

/** The exhaustive state vocabulary (services/kubernetes.STATES) with the Kubernetes reason behind it. */
export type ObjectState = 'healthy' | 'progressing' | 'degraded' | 'failed' | 'completed' | 'suspended'
  | 'pending' | 'terminating' | 'unknown' | 'static';

export interface StateInfo {
  state: ObjectState;
  reason: string | null;
  detail: string;
  /** From configs/kubernetes_reasons.json when the reason is known: what it means and what to do. */
  explain: { reason: string; title?: string; explanation?: string; fix?: string; doc?: string } | null;
}

export interface NodeSummary {
  name: string; roles: string[]; ready: string; unschedulable: boolean; taints: string[]; pressure: string[];
  internal_ip: string | null; kubelet_version: string | null; os_image: string | null; container_runtime: string | null;
  capacity: Record<string, string | null>; allocatable: Record<string, string | null>; age_seconds: number | null; state: StateInfo;
}
export interface NamespaceSummary {
  name: string; phase: string | null; pod_security: Record<string, string>; system: boolean; age_seconds: number | null; state: StateInfo;
}
export interface ApiResource {
  name: string; short_names: string[]; api_version: string; group: string; version: string; namespaced: boolean;
  kind: string; verbs: string[]; categories: string[];
}
export interface Inventory {
  server_version: string | null; client_version: string | null; server_url: string | null;
  nodes: NodeSummary[]; namespaces: NamespaceSummary[]; api_resources: ApiResource[];
  workloads: { totals: Record<string, number>; by_namespace: Record<string, { counts: Record<string, number>; unhealthy: number; pods: Record<string, number> }> };
  storage_classes: { name: string; provisioner: string | null; default: boolean; binding_mode: string | null }[];
  ingress_classes: string[];
  quotas: { namespace: string; name: string; hard: Record<string, string> }[];
  recent_warnings: { namespace: string | null; reason: string; message: string; count: number | null; object: string; last_seen: string | null }[];
  observed_at: string;
}
export interface InventoryResponse {
  cluster_id: string; inventory: Inventory; observed_at: string | null; reachability: Reachability;
  unreachable_reason: string | null; stale: boolean;
}

export interface ObjectRow {
  kind: string; api_version: string; name: string; namespace: string | null; labels: Record<string, string>;
  age_seconds: number | null; state: StateInfo; summary: Record<string, unknown>;
}
export interface ObjectList { kind: string; namespace: string | null; count: number; items: ObjectRow[]; warnings: string | null; }

export interface ObjectDetail {
  object: Record<string, unknown>; row: ObjectRow; metadata: Record<string, unknown>;
  spec: Record<string, unknown> | null; status: Record<string, unknown> | null; data_keys: string[] | null;
  field_managers: string[];
  versions: { resource_version: string | null; generation: number | null; observed_generation: number | null; uid: string | null };
  etcd_key: string; warnings: string | null;
}

export interface K8sEvent {
  type: string; reason: string; message: string; count: number | null; object: string; namespace: string | null;
  first_seen: string | null; last_seen: string | null; source: string | null; explain: StateInfo['explain'];
}
export interface LogsResponse { pod: string; container: string | null; previous: boolean; tail?: number; lines: string[]; truncated?: boolean; error?: string; }

/** The Application form (services/kubernetes_app.AppForm) — the click form that becomes a set of objects. */
export interface AppPort { port: number; name?: string; protocol?: 'TCP' | 'UDP' | 'SCTP'; }
export interface AppProbe { kind: 'none' | 'http' | 'tcp' | 'exec'; path?: string; port?: number | null; command?: string[];
  initial_delay_seconds?: number; period_seconds?: number; timeout_seconds?: number; failure_threshold?: number; }
export interface AppContainer {
  name?: string; image: string; ports: AppPort[]; command?: string[]; args?: string[]; env: Record<string, string>;
  env_from?: { kind: 'configmap' | 'secret'; name: string; optional?: boolean }[];
  config_mounts?: { kind: 'configmap' | 'secret'; name: string; mount_path: string; read_only?: boolean }[];
  preset: 'small' | 'medium' | 'large' | 'custom' | 'none'; cpu_request?: string; memory_request?: string; cpu_limit?: string; memory_limit?: string;
  readiness: AppProbe; liveness: AppProbe; startup: AppProbe; image_pull_policy?: '' | 'IfNotPresent' | 'Always' | 'Never'; init?: boolean;
}
export interface AppVolume { name: string; mount_path: string; size: string; storage_class?: string; access_mode?: 'ReadWriteOnce' | 'ReadWriteMany' | 'ReadOnlyMany' | 'ReadWriteOncePod'; existing_claim?: string; }
export interface AppForm {
  name: string; namespace: string; description?: string;
  run_mode: 'replicated' | 'every_node' | 'once' | 'scheduled'; replicas: number; data_mode: 'none' | 'shared' | 'per_instance';
  containers: AppContainer[]; volumes: AppVolume[]; empty_dirs?: { name: string; mount_path: string; memory?: boolean; size_limit?: string }[];
  expose: { enabled: boolean; type: 'ClusterIP' | 'NodePort' | 'LoadBalancer'; port?: number | null; target_port?: number | null; node_port?: number | null; session_affinity?: boolean };
  ingress: { enabled: boolean; host?: string; path?: string; path_type?: 'Prefix' | 'Exact' | 'ImplementationSpecific'; class_name?: string; tls_secret?: string };
  hpa: { enabled: boolean; min_replicas: number; max_replicas: number; cpu_percent: number };
  pdb: { enabled: boolean; min_available: string };
  rollout?: { max_surge: string; max_unavailable: string; recreate: boolean; min_ready_seconds: number; revision_history_limit: number; progress_deadline_seconds: number };
  schedule?: { schedule: string; timezone?: string; concurrency_policy: 'Allow' | 'Forbid' | 'Replace'; suspend: boolean; successful_history: number; failed_history: number;
    backoff_limit: number; completions: number; parallelism: number; ttl_seconds_after_finished: number | null; active_deadline_seconds?: number | null };
  placement: { node_selector: Record<string, string>; tolerations?: Record<string, unknown>[]; spread_across_nodes: boolean; required_spread: boolean };
  security: { profile: 'restricted' | 'baseline' | 'privileged'; run_as_user?: number | null; run_as_group?: number | null; fs_group?: number | null;
    read_only_root_filesystem: boolean; service_account?: string; automount_service_account_token?: boolean | null; image_pull_secret?: string };
  labels: Record<string, string>; annotations?: Record<string, string>; part_of?: string; component?: string; create_namespace: boolean;
  /** An existing workload's immutable selector, carried over on edit; empty → generated from the name. */
  selector?: Record<string, string>;
}
export interface AppIssue { level: 'error' | 'warning'; field: string; message: string; }
export interface AppObjectPlan { kind: string; name: string; namespace: string | null; action: string; changed_count: number; refused: boolean;
  reason: string | null; diff_text: string | null; server_warnings: string | null;
  /** The namespace this set creates first, when the server could not validate the object for that reason
   * alone — NOT a server verdict on the object; `reason` says so. */
  deferred?: string | null; }
export interface AppRender { kind: string; why: string; objects: { kind: string; name: string }[]; manifests: Record<string, unknown>[]; issues: AppIssue[]; plans?: AppObjectPlan[]; }
export interface AppApplyResult extends AppRender {
  dry_run: boolean; ok?: boolean; applied?: boolean; status?: string; awaiting_approval?: boolean; proposal_id?: string; error?: string;
  results?: { kind: string; name: string; ok: boolean; generation?: number; error?: string; warnings?: string | null }[];
}

/** One operator action and whether it applies right now — with the reason when it does not. */
export interface ActionInfo { action: string; applies: boolean; available: boolean; reason: string; verb: string; current?: number | null; }
export interface ActionsResponse { kind: string; name: string | null; namespace: string | null; actions: ActionInfo[]; rollout_history: { revision: number; change_cause: string | null }[]; }
export interface ActionBody { action: string; kind: string; name: string; namespace?: string | null; revision?: number | null; force?: boolean; grace_period?: number | null; replicas?: number | null; require_approval?: boolean; note?: string | null; }
export interface ActionResult { action: string; ok?: boolean; meaning?: string; stdout?: string; stderr?: string | null; rc?: number; error?: string;
  applied?: boolean; status?: string; awaiting_approval?: boolean; proposal_id?: string; generation?: number; }

@Injectable({ providedIn: 'root' })
export class KubernetesService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/kubernetes/clusters`;

  list() { return this.http.get<KubernetesCluster[]>(this.base); }
  get(id: string) { return this.http.get<KubernetesCluster>(`${this.base}/${id}`); }
  create(body: KubernetesClusterInput) { return this.http.post<KubernetesCluster>(this.base, body); }
  update(id: string, body: KubernetesClusterInput, version: string) {
    const headers = version ? new HttpHeaders({ 'If-Match': version }) : undefined;
    return this.http.put<KubernetesCluster>(`${this.base}/${id}`, body, headers ? { headers } : {});
  }
  /** Forgets the registration and its cache; nothing on the cluster or the access host is touched. */
  delete(id: string) { return this.http.delete<void>(`${this.base}/${id}`); }
  probe(id: string) {
    return this.http.post<{ reachability: Reachability; reason: string | null; server_version: string | null; access_host: string }>(`${this.base}/${id}/probe`, {});
  }
  inventory(id: string, refresh = false) {
    let params = new HttpParams();
    if (refresh) params = params.set('refresh', 'true');
    return this.http.get<InventoryResponse>(`${this.base}/${id}/inventory`, { params });
  }
  apiResources(id: string) { return this.http.get<{ count: number; resources: ApiResource[] }>(`${this.base}/${id}/api-resources`); }
  objects(id: string, kind: string, namespace: string | null, selector?: string) {
    let params = new HttpParams().set('kind', kind);
    if (namespace) params = params.set('namespace', namespace); else params = params.set('all_namespaces', 'true');
    if (selector) params = params.set('selector', selector);
    return this.http.get<ObjectList>(`${this.base}/${id}/objects`, { params });
  }
  object(id: string, kind: string, name: string, namespace: string | null) {
    let params = new HttpParams();
    if (namespace) params = params.set('namespace', namespace);
    return this.http.get<ObjectDetail>(`${this.base}/${id}/objects/${encodeURIComponent(kind)}/${encodeURIComponent(name)}`, { params });
  }
  pods(id: string, namespace: string, selector: string) {
    return this.http.get<ObjectList>(`${this.base}/${id}/pods`, { params: { namespace, selector } });
  }
  events(id: string, opts: { namespace?: string | null; name?: string; kind?: string; all?: boolean }) {
    let params = new HttpParams();
    if (opts.namespace) params = params.set('namespace', opts.namespace);
    if (opts.all) params = params.set('all_namespaces', 'true');
    if (opts.name) params = params.set('name', opts.name);
    if (opts.kind) params = params.set('kind', opts.kind);
    return this.http.get<{ count: number; events: K8sEvent[] }>(`${this.base}/${id}/events`, { params });
  }
  appRender(id: string, form: AppForm) { return this.http.post<AppRender>(`${this.base}/${id}/applications/render`, form); }
  appPlan(id: string, form: AppForm) { return this.http.post<AppRender>(`${this.base}/${id}/applications/plan`, form); }
  appApply(id: string, form: AppForm, dryRun: boolean, requireApproval: boolean, note?: string) {
    return this.http.post<AppApplyResult>(`${this.base}/${id}/applications/apply`, { form, dry_run: dryRun, require_approval: requireApproval, note: note || null });
  }
  appGet(id: string, namespace: string, name: string) {
    return this.http.get<{ form: AppForm; kind: string; related: string[] }>(`${this.base}/${id}/applications/${encodeURIComponent(namespace)}/${encodeURIComponent(name)}`);
  }
  actions(id: string, kind: string, name: string, namespace: string | null) {
    let params = new HttpParams().set('kind', kind).set('name', name);
    if (namespace) params = params.set('namespace', namespace);
    return this.http.get<ActionsResponse>(`${this.base}/${id}/actions`, { params });
  }
  runAction(id: string, body: ActionBody) { return this.http.post<ActionResult>(`${this.base}/${id}/actions`, body); }
  logs(id: string, namespace: string, pod: string, container?: string | null, tail = 200, previous = false) {
    let params = new HttpParams().set('namespace', namespace).set('pod', pod).set('tail', String(tail)).set('previous', String(previous));
    if (container) params = params.set('container', container);
    return this.http.get<LogsResponse>(`${this.base}/${id}/logs`, { params });
  }
}

/** State → the app's badge palette (status.util's ok/warn/crit/unknown), plus a label a person reads. */
export function stateBadge(state: ObjectState): 'good' | 'warn' | 'bad' | 'none' {
  switch (state) {
    case 'healthy': case 'completed': return 'good';
    case 'progressing': case 'pending': case 'suspended': case 'terminating': return 'warn';
    case 'degraded': case 'failed': return 'bad';
    default: return 'none';
  }
}
export const STATE_LABEL: Record<ObjectState, string> = {
  healthy: 'Healthy', progressing: 'Rolling out', degraded: 'Degraded', failed: 'Failed', completed: 'Completed',
  suspended: 'Suspended', pending: 'Pending', terminating: 'Terminating', unknown: 'Unknown', static: '—',
};
