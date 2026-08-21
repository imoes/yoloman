import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, concat, of, tap } from 'rxjs';
import { environment } from '../../../environments/environment';
import { HttpParams } from '@angular/common/http';
import { AccountsResponse, Agent, DirectiveSpec, EbpfDetail, ProcessHistory, GroupAction, LatestMetricsResponse, LogFilters, LogsResponse, MetricCatalogResponse, MetricSeriesResponse, NetworkConfig, NetworkResponse, ObservedStateResponse, PiggybackSource, ProcessesResponse, ServicesResponse, ConfigResource, ConfigTemplate, ConfigTemplateIndex, Device, StatePlan, StateResourceChange, StateGenerationsResponse, StateRollbackResponse, StorageResponse, UpdatesResponse, UserAction, VirtResponse } from '../models/agent.model';

/** Block J4a — the service-control actions the agent's systemd module accepts. */
export type ServiceAction = 'restart' | 'stop' | 'start' | 'enable' | 'disable';

// --- Kubernetes / Helm app tier -----------------------------------------
export interface HelmRelease {
  name: string; namespace: string; chart: string; app_version: string; status: string; revision: number;
}
export interface HelmReleasesResponse { agent: { id: string; name: string }; releases: HelmRelease[]; count: number; error?: string; }
export interface HelmChart { name: string; version: string; app_version: string; description: string; }
export interface HelmChartsResponse { charts: HelmChart[]; count: number; }
export interface HelmValuesResponse {
  chart: string; values_yaml: string; chart_yaml: string;
  values_schema: Record<string, { type: string; default?: unknown; enum?: unknown[]; description?: string }>;
  flat_values: Record<string, unknown>;
  error: string | null;
}
export interface HelmRenderResponse { rendered: string; ok: boolean; error: string | null; }
export interface HelmMutationResponse { name: string; namespace?: string; ok: boolean; stdout?: string; error: string | null; }

// --- Docker app tier -----------------------------------------------------
export interface DockerContainer { name: string; image: string; status: string; ports?: string; }
export interface DockerContainersResponse { containers: DockerContainer[]; count: number; error?: string; }
export interface DockerDeployBody {
  name: string; image: string; ports?: { host: number | string; container: number | string }[];
  env?: Record<string, string>; volumes?: string[]; restart?: string; dry_run?: boolean;
}
export interface DockerMutationResponse {
  container: string; image?: string; command?: string; ok?: boolean; rc?: number;
  stdout?: string; stderr?: string; dry_run?: boolean;
}

@Injectable({ providedIn: 'root' })
export class AgentService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/agents`;

  list() {
    return this.http.get<Agent[]>(this.base);
  }

  // Stale-while-revalidate: the host-properties header paints from cache
  // instantly on revisit, then refreshes from the network in place.
  private agentCache = new Map<string, Agent>();

  get(id: string): Observable<Agent> {
    const net = this.http.get<Agent>(`${this.base}/${id}`).pipe(tap((a) => this.agentCache.set(id, a)));
    const cached = this.agentCache.get(id);
    return cached !== undefined ? concat(of(cached), net) : net;
  }

  /** Catalog discovery: every metric name recorded for this agent. */
  metricNames(id: string) {
    return this.http.get<MetricCatalogResponse>(`${this.base}/${id}/metrics`);
  }

  /** The whole latest-data snapshot: newest sample of every metric, in one
   * call (powers the host-detail Metrics tab's list). */
  metricsLatest(id: string) {
    return this.http.get<LatestMetricsResponse>(`${this.base}/${id}/metrics/latest`);
  }

  /** Latest sample per unique (metric, LABELS) series — one row per filesystem,
   * per core, per device. `metricsLatest` above is DISTINCT ON (metric) and so
   * collapses those to a single arbitrary row, which is fine for a metric list
   * but useless for "how many GB free on /var": that needs the mount's own row. */
  metricsSnapshot(id: string) {
    return this.http.get<LatestMetricsResponse>(`${this.base}/${id}/metrics/snapshot`);
  }

  metricSeries(id: string, metric: string, since?: string) {
    let url = `${this.base}/${id}/metrics?metric=${encodeURIComponent(metric)}`;
    if (since) url += `&since=${encodeURIComponent(since)}`;
    return this.http.get<MetricSeriesResponse>(url);
  }

  /** Block J1: the agent's live process table (on-demand pass-through — the
   * agent samples CPU% over a short window per request, so this is not
   * cached server-side). limit>0 keeps only the top-N hungriest. */
  processes(id: string, limit = 0) {
    let url = `${this.base}/${id}/processes`;
    if (limit > 0) url += `?limit=${limit}`;
    return this.http.get<ProcessesResponse>(url);
  }

  /** On-demand eBPF detail behind the latency heatmaps: top outbound
   * connection targets + slowest recent disk I/O (the 'what'). */
  ebpf(id: string, limit = 20) {
    return this.http.get<EbpfDetail>(`${this.base}/${id}/ebpf?limit=${limit}`);
  }

  /** CPU%/RSS history for one process, keyed by command name (comm) so it
   * survives restarts — the combined-graph source behind an expanded
   * Processes-tab row. */
  processHistory(id: string, comm: string, since?: string) {
    let url = `${this.base}/${id}/processes/history?comm=${encodeURIComponent(comm)}`;
    if (since) url += `&since=${encodeURIComponent(since)}`;
    return this.http.get<ProcessHistory>(url);
  }

  /** Block F1 — the host as one JSON document: discovered services + each
   * config file read back structured via its codec (or a sha256 ref). Live
   * pass-through proxied to the agent's GET /api/v1/state/observed. */
  observedState(id: string, refresh = false) {
    // Default: served from Bossman's Postgres cache (fast). refresh=true forces
    // a live fetch from the agent and updates the cache (the Reload button).
    const q = refresh ? '?refresh=true' : '';
    return this.http.get<ObservedStateResponse>(`${this.base}/${id}/state/observed${q}`);
  }

  /** Block F2 — the host's local desired-state generation history (newest
   * first): what it has applied and can roll back to. */
  stateGenerations(id: string) {
    return this.http.get<StateGenerationsResponse>(`${this.base}/${id}/state/generations`);
  }

  /** Block F2 — roll the host's config back to a past generation. dry_run
   * returns the plan (observed→target diff) without writing. */
  stateRollback(id: string, generation: number, dryRun: boolean) {
    return this.http.post<StateRollbackResponse>(`${this.base}/${id}/state/rollback`, { generation, dry_run: dryRun });
  }

  /** Push an edited config file back verbatim via the `copy` module — the
   * tier-3 raw fallback for files with no codec (motd, issue). Codec'd files go
   * through the value editor (statePlan/stateApply) instead. */
  writeFileContent(id: string, dest: string, content: string, dryRun: boolean) {
    return this.http.post<{ agent_id: string; tool: string; result: { changed: boolean; msg: string; data?: unknown } }>(
      `${this.base}/${id}/tools/copy`, { params: { dest, content, dry_run: dryRun } },
    );
  }

  /** Block K1 — diff a desired config Document (edited values) against the host
   * via the document loop; returns the per-key plan without writing. */
  statePlan(id: string, resources: ConfigResource[]) {
    return this.http.post<{ agent_id: string; changes: StateResourceChange[]; changed_count: number }>(
      `${this.base}/${id}/state/plan`, { resources },
    );
  }

  /** Block K1 — apply edited config values through the codec merge; records a
   * generation (versioned + roll-backable). dry_run=true just returns the plan. */
  stateApply(id: string, resources: ConfigResource[], dryRun: boolean, scope?: { ouId?: string; groupId?: string }) {
    const body: Record<string, unknown> = { resources, dry_run: dryRun };
    if (scope?.ouId) body['ou_id'] = scope.ouId; // K4: OU policy + converge members
    if (scope?.groupId) body['host_group_id'] = scope.groupId; // K4: group policy
    return this.http.post<{ agent_id: string; plan?: StatePlan; generation?: number; dry_run: boolean; scope?: string; applied_hosts?: string[] }>(
      `${this.base}/${id}/state/apply`, body,
    );
  }

  /** Block K2 — the Class-B config template catalog (name + j2 text + schema +
   * sample). Bossman-level, not agent-scoped.
   *
   * 33.7 MB across 5460 templates. Use configTemplateIndex() to ask "which template renders this
   * file" and configTemplate(name) to fetch the one the user actually opened. */
  configTemplates() {
    return this.http.get<{ templates: ConfigTemplate[] }>(`${environment.apiUrl}/config-templates`);
  }

  /** path → template, built from the role catalog's config_path plus the codec registry.
   *
   * Replaces resolving by basename, which matched /etc/aardvark-dns/aardvark-dns.conf to the template
   * that renders forward.conf — and the write path is whole-file, so that would have overwritten one
   * file with another's content. */
  configTemplateIndex(agentId?: string) {
    // Passing the host lets the SERVER pick the template that renders THIS host's file:
    // /etc/caddy/Caddyfile exists on Debian and RedHat with different content. The family is derived
    // server-side from the host's facts — deriving it here would put one rule in two languages.
    const q = agentId ? `?agent_id=${encodeURIComponent(agentId)}` : '';
    return this.http.get<ConfigTemplateIndex>(`${environment.apiUrl}/config-templates/index${q}`);
  }

  /** One template with its body, schema and sample — fetched when the user opens the editor. */
  configTemplate(name: string) {
    return this.http.get<ConfigTemplate>(
      `${environment.apiUrl}/config-templates/${encodeURIComponent(name)}`);
  }

  /** Block F5 — the guests this host reports via piggyback (Docker containers,
   * Proxmox/vSphere/libvirt VMs) with their latest metrics. */
  piggyback(id: string) {
    return this.http.get<{ agent_id: string; guests: { name: string; mode: string; metrics: Record<string, number> }[] }>(
      `${this.base}/${id}/piggyback`,
    );
  }

  /** The GPO-resolved desired config for a host (no live-agent contact) — the
   * merged config files + per-key winning value/origin. Feeds the desired-state
   * report's Configuration section. */
  configDesired(agentId: string) {
    return this.http.get<{
      agent_id: string;
      resources: { path: string; format: string | null; values: Record<string, unknown>; source: string; key_sources: Record<string, string> }[];
    }>(`${environment.apiUrl}/agents/${agentId}/config-desired`);
  }

  /** The codec registry as a flat catalog — every known config file + its codec.
   * The gpedit uses it as its file catalog (host-independent), so a policy can
   * target ANY config file, not just those a sample host happens to have. */
  configCodecs() {
    return this.http.get<{ entries: { pattern: string; codec: string; separator: string; paths: string[] }[]; available: boolean }>(
      `${environment.apiUrl}/config-codecs`,
    );
  }

  /** ADMX — the per-directive value catalog ({file: {directive: spec}}), used
   * by the gpedit editor to offer real per-directive listboxes. */
  configDirectives() {
    return this.http.get<{ directives: Record<string, Record<string, DirectiveSpec>>; available: boolean }>(
      `${environment.apiUrl}/config-directives`,
    );
  }

  /** The unified describe() for ONE file: {path, write, format?, separator?,
   * template?, fields:{key:FieldDef}} — codec⊕directive for codec'd files, the
   * template schema for freeform. The single field-spec source (config-model
   * consolidation); replaces reading the raw directive catalog per file. */
  configFields(path: string, agentId?: string) {
    return this.http.get<{
      /** codec = per-key merge · template = whole-file render · freeform = measured, no grammar and no
       * template yet (raw text only) · unknown = nothing recorded about this path. `reason` carries the
       * why for the last two, so a screen never has to say "no fields" without saying why. */
      path: string; write: string; reason?: string; format?: string; separator?: string; template?: string;
      /** Where this answer comes from: measured=true means the grammar was decided by round-tripping the
       * file the package really ships; false means it was never checked against a real file. */
      provenance?: { source: string; measured: boolean; confidence: string; note: string };
      fields: Record<string, { type: string; enum?: string[]; default?: unknown; description?: string; min?: number; max?: number }>;
      available: boolean;
      /** Present only when the FILE ITSELF says it is machine-written, with the sentence that says so.
       * Not a write state and not a refusal — munin.conf is parsable, has directives, and still asks not
       * to be edited. The editor quotes it and the operator decides. */
      machine_written?: { line: number; quote: string; marker: string };
      /** For a template write: the directory name, its sample values, and the fields the template does NOT
       * place — offered inputs whose value could never reach the file. */
      template_name?: string;
      sample?: Record<string, unknown>;
      withheld?: { count: number; fields: string[]; reason: string } | null;
      /** The same gap from the other side: values the template READS that no field offers, so they render
       * empty. Templates needing more than their form offers are refused outright and never get here. */
      unsettable?: { count: number; variables: string[]; reason: string } | null;
    }>(`${environment.apiUrl}/config-fields?path=${encodeURIComponent(path)}`
       + (agentId ? `&agent_id=${encodeURIComponent(agentId)}` : ''));
  }

  /** {path: {line, quote, marker}} for every config file whose own header declares it machine-written.
   * A map, because the file lists render dozens of paths at once — asking config-fields per row would
   * trade one small read for forty. */
  configGenerated() {
    return this.http.get<{ files: Record<string, { line: number; quote: string; marker: string }>; count: number }>(
      `${environment.apiUrl}/config-generated`,
    );
  }

  // Block 3 — agent-less devices (snmp|ssh), polled via the co-located poller.
  devices() {
    return this.http.get<Device[]>(`${environment.apiUrl}/devices`);
  }
  createDevice(body: {
    name: string; kind: 'snmp' | 'ssh'; target: string; check_names: string[];
    community?: string; user?: string; password?: string;
    // SNMP v3 (USM)
    snmp_version?: 'v2c' | 'v3'; sec_level?: string; sec_name?: string;
    auth_proto?: string; auth_pass?: string; priv_proto?: string; priv_pass?: string; context?: string;
  }) {
    return this.http.post<Device>(`${environment.apiUrl}/devices`, body);
  }
  deleteDevice(id: string) {
    return this.http.delete<{ deleted: string }>(`${environment.apiUrl}/devices/${id}`);
  }

  /** Force an immediate poll of this agent — the same full cycle the
   * background poller runs (metrics/edges/hosts-overview pull, state
   * evaluation, AND the host's assigned Starlark checks), on demand instead
   * of waiting for the next tick. Returns what the poll wrote. */
  pollNow(id: string) {
    return this.http.post<{ agent_id: string; agent_name: string; metrics_written: number; satellites_discovered: number; edges_written: number; errors: string[] }>(
      `${this.base}/${id}/poll-now`, {},
    );
  }

  /** F-9 — the piggyback sources this host is configured with + live status. */
  piggybackSources(id: string) {
    return this.http.get<{ agent_id: string; sources: PiggybackSource[] }>(
      `${this.base}/${id}/piggyback/sources`,
    );
  }
  /** F-9 — add/replace a remote Proxmox/vSphere piggyback source at runtime. */
  addPiggybackSource(id: string, body: { type: string; host: string; user: string; password: string; insecure: boolean }) {
    return this.http.post<{ added: string; host: string }>(`${this.base}/${id}/piggyback/sources`, body);
  }
  /** F-9 — remove a remote piggyback source (by type + host). */
  removePiggybackSource(id: string, type: string, host: string) {
    return this.http.delete<{ removed: string; host: string }>(
      `${this.base}/${id}/piggyback/sources`, { params: { type, host } },
    );
  }

  /** Block K3/G — drift + the GPO-resolved desired values: per path the merged
   * desired values, per key the winning level (host/ou/group), and the drifted
   * resources. Drives the settings editor's State/Value/Source columns. */
  configDrift(id: string) {
    return this.http.get<{
      agent_id: string; managed: string[]; drift: StateResourceChange[];
      sources?: Record<string, string>;
      desired?: Record<string, Record<string, unknown>>;
      key_sources?: Record<string, Record<string, string>>;
    }>(`${this.base}/${id}/config-drift`);
  }

  /** Block G — GPO "Not configured": stop managing one key at one scope (the
   * live file is untouched; the key stops being enforced/drift-checked). */
  unsetDesired(id: string, body: { path: string; key: string; ou_id?: string; host_group_id?: string }) {
    return this.http.post<{ path: string; key: string; unset: boolean }>(
      `${this.base}/${id}/config-desired/unset`, body,
    );
  }

  /** Block K3 — re-sync the host to its recorded desired config (converge drift,
   * records a generation). */
  reapplyConfig(id: string) {
    return this.http.post<{ agent_id: string; generation: number }>(`${this.base}/${id}/config/reapply`, {});
  }

  /** Block K2 — render a template (inline j2 + values) on the host via
   * template_render dry-run, returning the rendered file text (data.rendered)
   * without writing — the template-form preview. */
  renderTemplate(id: string, template: string, values: Record<string, unknown>, dest: string) {
    return this.http.post<{ agent_id: string; tool: string; result: { changed: boolean; data?: { rendered?: string } } }>(
      `${this.base}/${id}/tools/template_render`, { params: { template, values, dest, dry_run: true } },
    );
  }

  /** Self-documenting infra: the LLM documents this host (no question) or
   * answers one, grounded strictly in its live server-document. */
  explainHost(id: string, question?: string) {
    return this.http.post<{ agent: { id: string; name: string }; question: string | null; answer: string;
      grounding: { context_chars: number; sections: string[]; errors: Record<string, string> } }>(
      `${this.base}/${id}/explain`, { question: question || null });
  }

  // --- Kubernetes / Helm app tier (click-and-play deploy) ---------------
  /** Deployed releases on the host's cluster (helm list -A). */
  helmReleases(id: string) {
    return this.http.get<HelmReleasesResponse>(`${this.base}/${id}/helm/releases`);
  }
  /** Available charts to deploy (helm search repo) — the k8s app catalog. */
  helmCharts(id: string, query = '') {
    return this.http.get<HelmChartsResponse>(`${this.base}/${id}/helm/charts`, { params: { query } });
  }
  /** A chart's default values.yaml — drives the configure form. */
  helmValues(id: string, chart: string) {
    return this.http.get<HelmValuesResponse>(`${this.base}/${id}/helm/values`, { params: { chart } });
  }
  /** helm template — render manifests without a cluster (preview). `values` is a
   * flat dotted-key form map the backend converts to YAML. */
  helmRender(id: string, body: { name: string; chart: string; values_yaml?: string; values?: Record<string, unknown>; namespace?: string }) {
    return this.http.post<HelmRenderResponse>(`${this.base}/${id}/helm/render`, body);
  }
  /** helm upgrade --install — deploy/upgrade a release. */
  helmInstall(id: string, body: { name: string; chart: string; values_yaml?: string; values?: Record<string, unknown>; namespace?: string; create_namespace?: boolean; wait?: boolean }) {
    return this.http.post<HelmMutationResponse>(`${this.base}/${id}/helm/install`, body);
  }
  helmRollback(id: string, body: { name: string; revision?: number; namespace?: string }) {
    return this.http.post<HelmMutationResponse>(`${this.base}/${id}/helm/rollback`, body);
  }
  helmUninstall(id: string, body: { name: string; namespace?: string }) {
    return this.http.post<HelmMutationResponse>(`${this.base}/${id}/helm/uninstall`, body);
  }

  // --- Docker app tier (click-and-play deploy) --------------------------
  dockerContainers(id: string) {
    return this.http.get<DockerContainersResponse>(`${this.base}/${id}/docker/containers`);
  }
  dockerDeploy(id: string, body: DockerDeployBody) {
    return this.http.post<DockerMutationResponse>(`${this.base}/${id}/docker/deploy`, body);
  }
  dockerRemove(id: string, name: string) {
    return this.http.post<DockerMutationResponse>(`${this.base}/${id}/docker/remove`, { name });
  }

  updateGroups(id: string, groups: string[]) {
    return this.http.patch<Agent>(`${this.base}/${id}/groups`, { groups });
  }

  /** Remove a host and everything it owns (metrics/services/downtimes/…);
   * satellites polled through it are orphaned, not deleted. 204 on success. */
  delete(id: string) {
    return this.http.delete<void>(`${this.base}/${id}`);
  }

  /** Push a new agent .deb to an enrolled host; the agent installs it and
   * restarts onto the new version (works even for write=false agents). */
  update(id: string, deb: File) {
    const form = new FormData();
    form.append('file', deb, deb.name);
    return this.http.post<{ agent_id: string; result: unknown }>(`${this.base}/${id}/update`, form);
  }

  /** Push the package Bossman ships (no file pick) — the server picks .deb vs
   * .rpm by the host's OS family. */
  updateBundled(id: string) {
    return this.http.post<{ agent_id: string; family: string; package: string; result: unknown }>(
      `${this.base}/${id}/update-bundled`, {});
  }

  /** Block J2/J4a: restart/stop/start a systemd unit's running state, or
   * enable/disable its start-at-boot state, through the agent's write-gated
   * + audited `systemd` module. No raw PID-kill. */
  serviceControl(id: string, service: string, action: ServiceAction) {
    return this.http.post<{ agent_id: string; service: string; action: string; result: unknown }>(
      `${this.base}/${id}/service-control`,
      { service, action },
    );
  }

  /** Reconfigure the agent over the API (its self-config carve-out): the metric-collection knobs and the
   * master `write` gate. Enabling writes is how a freshly PXE-provisioned, read-only host is allowed to
   * converge its assigned roles. The agent writes its config.yaml and restarts to apply. */
  setAgentConfig(id: string, patch: { write?: boolean; services?: boolean; psi?: boolean; docker?: boolean; drbd_devices?: boolean; interval?: string }) {
    return this.http.post<{ agent_id: string; applied: Record<string, unknown>; result: unknown }>(
      `${this.base}/${id}/collect-config`, patch,
    );
  }

  /** Block J4a: the host's full systemd service-unit list + load/active/sub
   * state, via the read-only `service_facts` module (live pass-through). */
  services(id: string) {
    return this.http.get<ServicesResponse>(`${this.base}/${id}/service-units`);
  }

  /** Block J4b: the host's journald log via the read-only `journal` module
   * (journalctl -o json), optionally filtered by unit/priority/since/grep. */
  logs(id: string, filters: LogFilters = {}) {
    let params = new HttpParams();
    for (const [k, v] of Object.entries(filters)) {
      if (v !== undefined && v !== null && v !== '') params = params.set(k, String(v));
    }
    return this.http.get<LogsResponse>(`${this.base}/${id}/logs`, { params });
  }

  /** /var/log file listing via the read-only, path-jailed `logfiles` module. */
  logFiles(id: string, extraPaths: string[] = []) {
    let params = new HttpParams();
    for (const p of extraPaths) if (p.trim()) params = params.append('extra_paths', p.trim());
    return this.http.get<{ agent_id: string; roots: string[]; files: { path: string; size: number; modified: number }[] }>(
      `${this.base}/${id}/logs/files`, { params },
    );
  }

  /** Tail one /var/log file (last N lines, optional grep) via `logfiles`.
   * grep is a substring by default; regex=true → grep -E, invert=true → grep -v. */
  logFile(id: string, path: string, lines = 500, grep = '', extraPaths: string[] = [], regex = false, invert = false) {
    let params = new HttpParams().set('path', path).set('lines', String(lines));
    if (grep) {
      params = params.set('grep', grep);
      if (regex) params = params.set('regex', 'true');
      if (invert) params = params.set('invert', 'true');
    }
    for (const p of extraPaths) if (p.trim()) params = params.append('extra_paths', p.trim());
    return this.http.get<{ agent_id: string; path: string; lines: string[]; truncated: boolean; size: number }>(
      `${this.base}/${id}/logs/file`, { params },
    );
  }

  /** Block J4c: the host's users + groups via the read-only `getent` module. */
  accounts(id: string) {
    return this.http.get<AccountsResponse>(`${this.base}/${id}/accounts`);
  }

  /** Block J4c: create/modify/remove a user via the write-gated `user` module. */
  manageUser(id: string, action: UserAction) {
    return this.http.post<{ agent_id: string; result: unknown }>(`${this.base}/${id}/accounts/user`, action);
  }

  /** Block J4c: create/remove a group via the write-gated `group` module. */
  manageGroup(id: string, action: GroupAction) {
    return this.http.post<{ agent_id: string; result: unknown }>(`${this.base}/${id}/accounts/group`, action);
  }

  /** Block J4d: read-only storage overview (block devices + LVM + VDO + ZFS). */
  storage(id: string) {
    return this.http.get<StorageResponse>(`${this.base}/${id}/storage`);
  }

  /** Generic fleet-router call: invoke one tool on the agent by name (fqcn for
   * baked/collection modules, bare name for natives). Used for storage write
   * actions (community.general.lvg/lvol/filesystem/vdo/zfs) and any MCP tool. */
  callTool(id: string, name: string, params: Record<string, unknown>) {
    return this.http.post<{ agent_id: string; tool: string; result: unknown }>(
      `${this.base}/${id}/tools/${encodeURIComponent(name)}`,
      { params },
    );
  }

  /** Push translated Starlark modules to the host so it can execute them
   * (Block G3). Pass fqcns to push a specific subset (e.g. the management
   * modules the Network/Storage actions need). */
  syncModules(id: string, fqcns?: string[]) {
    return this.http.post<{ pushed: number; result: { applied: number; results: { fqcn: string; ok: boolean }[] } }>(
      `${this.base}/${id}/modules/sync`,
      fqcns ? { fqcns } : {},
    );
  }

  /** Block J4e: current network config (interfaces/addresses/routes/DNS) via
   * the baked yoloman.network_interface module in gathered mode. */
  network(id: string) {
    return this.http.get<NetworkResponse>(`${this.base}/${id}/network`);
  }

  /** Block J4e: configure/remove an interface (NetworkManager, write-gated). */
  configureNetwork(id: string, config: NetworkConfig) {
    return this.http.post<{ agent_id: string; result: unknown }>(`${this.base}/${id}/network`, config);
  }

  /** Virtualization overview: detected hypervisor stack(s) + their guests
   * (Proxmox qm/pct, libvirt virsh) via the read-only virt_facts module. */
  virt(id: string) {
    return this.http.get<VirtResponse>(`${this.base}/${id}/virt`);
  }

  /** Cockpit "Software updates": pending OS package updates (apt/dnf/yum). */
  updates(id: string) {
    return this.http.get<UpdatesResponse>(`${this.base}/${id}/updates`);
  }

  /** Apply pending updates (all or security-only), write-gated, dry_run-aware. */
  applyUpdates(id: string, opts: { security_only?: boolean; dry_run?: boolean }) {
    return this.http.post<{ agent_id: string; result: unknown }>(`${this.base}/${id}/updates`, opts);
  }
}
