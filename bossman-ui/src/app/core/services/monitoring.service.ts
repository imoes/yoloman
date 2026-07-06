import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { CheckRule, CheckRuleInput, Downtime, FleetHost, FleetSummary, ServiceHistoryPoint, ServiceState } from '../models/monitoring.model';

export interface ProblemsFilter {
  state?: string;
  host?: string;
  acknowledged?: boolean;
  include_downtime?: boolean;
}

export interface DowntimeInput {
  agent_id: string;
  service_name?: string | null;
  starts_at: string;
  ends_at: string;
  comment?: string;
}

/** REST client for the CheckMK-style monitoring surface (see docs/plan.md's
 * monitoring Block E3/E4) — mirrors RunService/AgentService's shape. */
@Injectable({ providedIn: 'root' })
export class MonitoringService {
  private http = inject(HttpClient);
  private base = environment.apiUrl;

  problems(filter: ProblemsFilter = {}) {
    let params = new HttpParams();
    for (const [key, value] of Object.entries(filter)) {
      if (value !== undefined && value !== null && value !== '') {
        params = params.set(key, String(value));
      }
    }
    return this.http.get<ServiceState[]>(`${this.base}/problems`, { params });
  }

  agentServices(agentId: string) {
    return this.http.get<ServiceState[]>(`${this.base}/agents/${agentId}/services`);
  }

  serviceHistory(agentId: string, serviceName: string, limit = 200) {
    const params = new HttpParams().set('limit', String(limit));
    return this.http.get<ServiceHistoryPoint[]>(
      `${this.base}/agents/${agentId}/services/${encodeURIComponent(serviceName)}/history`,
      { params },
    );
  }

  acknowledge(serviceId: string, comment: string) {
    return this.http.post<ServiceState>(`${this.base}/services/${serviceId}/acknowledge`, { comment });
  }

  unacknowledge(serviceId: string) {
    return this.http.delete<ServiceState>(`${this.base}/services/${serviceId}/acknowledge`);
  }

  listDowntimes(agentId?: string) {
    let params = new HttpParams();
    if (agentId) params = params.set('agent_id', agentId);
    return this.http.get<Downtime[]>(`${this.base}/downtimes`, { params });
  }

  createDowntime(body: DowntimeInput) {
    return this.http.post<Downtime>(`${this.base}/downtimes`, body);
  }

  deleteDowntime(id: string) {
    return this.http.delete<void>(`${this.base}/downtimes/${id}`);
  }

  listCheckRules() {
    return this.http.get<CheckRule[]>(`${this.base}/check-rules`);
  }

  createCheckRule(body: CheckRuleInput) {
    return this.http.post<CheckRule>(`${this.base}/check-rules`, body);
  }

  updateCheckRule(id: string, body: CheckRuleInput) {
    return this.http.put<CheckRule>(`${this.base}/check-rules/${id}`, body);
  }

  deleteCheckRule(id: string) {
    return this.http.delete<void>(`${this.base}/check-rules/${id}`);
  }

  fleetSummary() {
    return this.http.get<FleetSummary>(`${this.base}/fleet/summary`);
  }

  fleetHosts() {
    return this.http.get<FleetHost[]>(`${this.base}/fleet/hosts`);
  }
}
