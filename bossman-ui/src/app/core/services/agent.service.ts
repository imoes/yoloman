import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { Agent, LatestMetricsResponse, MetricCatalogResponse, MetricSeriesResponse, ProcessesResponse, ServicesResponse } from '../models/agent.model';

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
    return this.http.get<ServicesResponse>(`${this.base}/${id}/services`);
  }
}
