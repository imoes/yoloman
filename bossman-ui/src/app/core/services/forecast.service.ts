import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { environment } from '../../../environments/environment';

export interface CapacityRow {
  agent_id: string;
  host: string;
  label: string;
  current: number;
  slope_per_day: number;
  days_to_threshold: number | null;
  eta: string | null;
  threshold: number;
  status: 'ok' | 'warning' | 'critical';
}

export interface CapacityQuery {
  metric?: string;
  threshold?: number;
  lookback_days?: number;
  warn_days?: number;
  crit_days?: number;
}

@Injectable({ providedIn: 'root' })
export class ForecastService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/forecast`;

  capacity(q: CapacityQuery = {}) {
    let p = new HttpParams();
    for (const [k, v] of Object.entries(q)) {
      if (v !== undefined && v !== null && v !== '') p = p.set(k, String(v));
    }
    return this.http.get<CapacityRow[]>(`${this.base}/capacity`, { params: p });
  }
}
