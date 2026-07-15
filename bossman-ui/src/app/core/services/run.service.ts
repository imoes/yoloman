import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { PlanRun, PlanRunDetail } from '../models/run.model';

export interface RunListFilter {
  agent_id?: string;
  plan_name?: string;
  status?: string;
  limit?: number;
}

@Injectable({ providedIn: 'root' })
export class RunService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/runs`;

  list(filter: RunListFilter = {}) {
    let params = new HttpParams();
    for (const [key, value] of Object.entries(filter)) {
      if (value !== undefined && value !== null && value !== '') {
        params = params.set(key, String(value));
      }
    }
    return this.http.get<PlanRun[]>(this.base, { params });
  }

  get(id: string) {
    return this.http.get<PlanRunDetail>(`${this.base}/${id}`);
  }

  /** Block F6 — runbook execution history (sibling of plan runs), for the
   * unified Runs page. */
  runbookRuns(limit = 100) {
    return this.http.get<{ runs: { id: string; runbook_name: string; agent_id: string | null; status: string; dry_run: boolean; changed: boolean; requested_by: string | null; created_at: string }[] }>(
      `${environment.apiUrl}/runbook-runs?limit=${limit}`,
    );
  }
}
