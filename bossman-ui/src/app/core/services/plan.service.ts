import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { Plan, PlanDetail, RunPlanRequest, RunPlanResponse } from '../models/plan.model';

@Injectable({ providedIn: 'root' })
export class PlanService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/plans`;

  list() {
    return this.http.get<Plan[]>(this.base);
  }

  get(name: string) {
    return this.http.get<PlanDetail>(`${this.base}/${encodeURIComponent(name)}`);
  }

  run(name: string, body: RunPlanRequest) {
    return this.http.post<RunPlanResponse>(`${this.base}/${encodeURIComponent(name)}/run`, body);
  }

  reload() {
    return this.http.post<{ reloaded: boolean; catalog_length: number }>(`${this.base}/reload`, {});
  }
}
