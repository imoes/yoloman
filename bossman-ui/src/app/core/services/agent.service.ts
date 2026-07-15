import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { HttpParams } from '@angular/common/http';
import { AccountsResponse, Agent, EbpfDetail, ProcessHistory, GroupAction, LatestMetricsResponse, LogFilters, LogsResponse, MetricCatalogResponse, MetricSeriesResponse, NetworkConfig, NetworkResponse, ObservedStateResponse, ProcessesResponse, ServicesResponse, StorageResponse, UpdatesResponse, UserAction, VirtResponse } from '../models/agent.model';

/** Block J4a — the service-control actions the agent's systemd module accepts. */
export type ServiceAction = 'restart' | 'stop' | 'start' | 'enable' | 'disable';

@Injectable({ providedIn: 'root' })
export class AgentService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/agents`;

  list() {
    return this.http.get<Agent[]>(this.base);
  }

  get(id: string) {
    return this.http.get<Agent>(`${this.base}/${id}`);
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
  observedState(id: string) {
    return this.http.get<ObservedStateResponse>(`${this.base}/${id}/state/observed`);
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

  /** Block J2/J4a: restart/stop/start a systemd unit's running state, or
   * enable/disable its start-at-boot state, through the agent's write-gated
   * + audited `systemd` module. No raw PID-kill. */
  serviceControl(id: string, service: string, action: ServiceAction) {
    return this.http.post<{ agent_id: string; service: string; action: string; result: unknown }>(
      `${this.base}/${id}/service-control`,
      { service, action },
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
