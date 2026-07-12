import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { CreateDashboardWidget, DashboardWidget, UpdateDashboardWidget, WidgetData } from '../models/dashboard.model';

/** REST client for the per-operator GridStack dashboard (see docs/plan.md's
 * monitoring-cockpit ergänzung Block F5) — mirrors MonitoringService's shape. */
@Injectable({ providedIn: 'root' })
export class DashboardService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/dashboard-widgets`;
  private dbBase = `${environment.apiUrl}/dashboards`;

  // ---- dashboards (named, multiple per user) ----
  listDashboards() {
    return this.http.get<Dashboard[]>(this.dbBase);
  }
  createDashboard(body: { name: string; source?: string; prompt?: string }) {
    return this.http.post<Dashboard>(this.dbBase, body);
  }
  updateDashboard(id: string, body: { name?: string; is_default?: boolean }) {
    return this.http.patch<Dashboard>(`${this.dbBase}/${id}`, body);
  }
  deleteDashboard(id: string) {
    return this.http.delete<void>(`${this.dbBase}/${id}`);
  }

  // ---- widgets (scoped to a dashboard) ----
  list(dashboardId?: string) {
    const q = dashboardId ? `?dashboard_id=${dashboardId}` : '';
    return this.http.get<DashboardWidget[]>(`${this.base}${q}`);
  }

  create(body: CreateDashboardWidget) {
    return this.http.post<DashboardWidget>(this.base, body);
  }

  update(id: string, body: UpdateDashboardWidget) {
    return this.http.patch<DashboardWidget>(`${this.base}/${id}`, body);
  }

  delete(id: string) {
    return this.http.delete<void>(`${this.base}/${id}`);
  }

  data(id: string) {
    return this.http.get<WidgetData>(`${this.base}/${id}/data`);
  }
}

export interface Dashboard {
  id: string;
  name: string;
  is_default: boolean;
  source: 'manual' | 'ai';
  prompt: string;
  context: Record<string, unknown>;
  created_at: string;
}
