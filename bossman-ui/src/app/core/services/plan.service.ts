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

  /** AI briefing (md + optional UML) shown above the run form. */
  briefing(name: string) {
    return this.http.post<PlanBriefing>(`${this.base}/${encodeURIComponent(name)}/briefing`, {});
  }

  reload() {
    return this.http.post<{ reloaded: boolean; catalog_length: number }>(`${this.base}/reload`, {});
  }

  // ---- plan library (folder tree + NT/YAML/JSON documents) ----

  /** Every stored plan/role (latest version) + its folder placement. */
  library() {
    return this.http.get<{ plans: StoredPlan[]; folders: string[] }>(`${environment.apiUrl}/plan-library`);
  }

  /** A stored version rendered in all three authoring formats (latest by default). */
  document(prefix: string, name: string, version?: number) {
    const q = version ? `?version=${version}` : '';
    return this.http.get<PlanDocument>(`${this.base}/stored/${prefix}/${encodeURIComponent(name)}/document${q}`);
  }

  /** All stored versions of a plan (newest first) for the diff picker. */
  versions(prefix: string, name: string) {
    return this.http.get<{ versions: PlanVersion[] }>(`${this.base}/stored/${prefix}/${encodeURIComponent(name)}/versions`);
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

  /** Run a plan straight from the store (used for AI-authored plans). */
  runStored(prefix: string, name: string, body: RunPlanRequest) {
    return this.http.post<RunPlanResponse>(
      `${this.base}/stored/${prefix}/${encodeURIComponent(name)}/run`, body,
    );
  }
}

export interface PlanBriefing { markdown: string | null; error: string | null; }
export interface StoredPlan { prefix: string; name: string; version: number; source_format: string; content_hash: string; folder: string; }
export interface PlanVersion { version: number; source_format: string; content_hash: string; created_at: string | null; created_by: string | null; }
export interface PlanDocument {
  prefix: string; name: string; version: number; source_format: string; folder: string;
  formats: { nt: string; yaml: string; json: string };
  source_text: string;
}
