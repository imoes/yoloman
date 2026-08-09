import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { Observable, concat, of, tap } from 'rxjs';
import { environment } from '../../../environments/environment';
import { Availability, CheckRule, CheckRuleInput, Downtime, EffectiveThreshold, FleetHost, FleetSummary, MetricCatalogEntry, ServiceHistoryPoint, ServiceState } from '../models/monitoring.model';

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

  // Stale-while-revalidate cache: emit the last known value immediately (so the
  // view paints instantly on revisit) then the fresh network value. The
  // subscriber's handler runs once per emission, so a signal set() shows cached
  // data then updates in place — no spinner on navigation.
  private fleetCache: FleetHost[] | null = null;
  private servicesCache = new Map<string, ServiceState[]>();

  private cacheFirst<T>(cached: T | undefined, net: Observable<T>): Observable<T> {
    return cached !== undefined ? concat(of(cached), net) : net;
  }

  agentServices(agentId: string) {
    const net = this.http.get<ServiceState[]>(`${this.base}/agents/${agentId}/services`)
      .pipe(tap((s) => this.servicesCache.set(agentId, s)));
    return this.cacheFirst(this.servicesCache.get(agentId), net);
  }

  /** Block E: which threshold rule wins on a host per metric/label, and why. */
  effectiveThresholds(agentId: string) {
    return this.http.get<EffectiveThreshold[]>(`${this.base}/agents/${agentId}/effective-thresholds`);
  }

  serviceHistory(agentId: string, serviceName: string, limit = 200) {
    const params = new HttpParams().set('limit', String(limit));
    return this.http.get<ServiceHistoryPoint[]>(
      `${this.base}/agents/${agentId}/services/${encodeURIComponent(serviceName)}/history`,
      { params },
    );
  }

  serviceAvailability(agentId: string, serviceName: string, hours = 24) {
    const params = new HttpParams().set('hours', String(hours));
    return this.http.get<Availability>(
      `${this.base}/agents/${agentId}/services/${encodeURIComponent(serviceName)}/availability`,
      { params },
    );
  }

  acknowledge(serviceId: string, comment: string, expireAfterMinutes: number | null = null) {
    return this.http.post<ServiceState>(`${this.base}/services/${serviceId}/acknowledge`, {
      comment,
      expire_after_minutes: expireAfterMinutes,
    });
  }

  unacknowledge(serviceId: string) {
    return this.http.delete<ServiceState>(`${this.base}/services/${serviceId}/acknowledge`);
  }

  /** Delete a service row and its history — for orphaned/stale services no
   * producer refreshes any more. If an active assignment/rule/builtin still
   * materialises it, the next poll recreates it; remove that producer first. */
  deleteService(serviceId: string) {
    return this.http.delete<void>(`${this.base}/services/${serviceId}`);
  }

  /** Acknowledge many problems at once (multi-select on the Problems table). */
  bulkAcknowledge(serviceIds: string[], comment: string, expireAfterMinutes: number | null = null) {
    return this.http.post<{ acknowledged: string[]; missing: string[]; count: number }>(
      `${this.base}/services/acknowledge-bulk`,
      { service_ids: serviceIds, comment, expire_after_minutes: expireAfterMinutes },
    );
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

  patchCheckRule(id: string, patch: { enforced?: boolean; enabled?: boolean; link_order?: number; scope_ou_id?: string }) {
    return this.http.patch<CheckRule>(`${this.base}/check-rules/${id}`, patch);
  }

  deleteCheckRule(id: string) {
    return this.http.delete<void>(`${this.base}/check-rules/${id}`);
  }

  /** Link a threshold policy to ANOTHER OU (one policy → many OUs). */
  addOuLink(id: string, ouId: string) {
    return this.http.post<CheckRule>(`${this.base}/check-rules/${id}/ou-links`, { ou_id: ouId });
  }

  /** Unlink a threshold policy from one OU (promotes another linked OU to
   * primary; refused for the last remaining OU). */
  removeOuLink(id: string, ouId: string) {
    return this.http.delete<CheckRule>(`${this.base}/check-rules/${id}/ou-links/${ouId}`);
  }

  fleetSummary() {
    return this.http.get<FleetSummary>(`${this.base}/fleet/summary`);
  }

  fleetHosts() {
    const net = this.http.get<FleetHost[]>(`${this.base}/fleet/hosts`)
      .pipe(tap((h) => (this.fleetCache = h)));
    return this.cacheFirst(this.fleetCache ?? undefined, net);
  }

  /** Block L3c: distinct fleet metrics + human-readable names for the
   * threshold dialog's live search. */
  metricCatalog() {
    return this.http.get<MetricCatalogEntry[]>(`${this.base}/metric-catalog`);
  }
}
