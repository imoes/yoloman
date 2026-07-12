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

  // ---- plan library (folder tree + NT/YAML/JSON documents) ----

  /** Every stored plan/role (latest version) + its folder placement. */
  library() {
    return this.http.get<{ plans: StoredPlan[]; folders: string[] }>(`${environment.apiUrl}/plan-library`);
  }

  /** The latest stored version rendered in all three authoring formats. */
  document(prefix: string, name: string) {
    return this.http.get<PlanDocument>(`${this.base}/stored/${prefix}/${encodeURIComponent(name)}/document`);
  }

  /** Place a plan/role into a folder path ("" = root). */
  move(prefix: string, name: string, folder: string) {
    return this.http.post<{ prefix: string; name: string; folder: string }>(
      `${this.base}/stored/${prefix}/${encodeURIComponent(name)}/move`, { folder },
    );
  }

  /** Save an edited plan as a new stored version (source_format ∈ nestedtext|yaml|json). */
  save(prefix: string, name: string, source_format: string, source_text: string) {
    return this.http.post<{ prefix: string; name: string; version: number }>(
      `${this.base}/stored`, { prefix, name, source_format, source_text },
    );
  }
}

export interface StoredPlan { prefix: string; name: string; version: number; source_format: string; content_hash: string; folder: string; }
export interface PlanDocument {
  prefix: string; name: string; version: number; source_format: string; folder: string;
  formats: { nt: string; yaml: string; json: string };
  source_text: string;
}
