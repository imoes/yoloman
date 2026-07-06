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

  list() {
    return this.http.get<DashboardWidget[]>(this.base);
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
