import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

/** A System member (an app on a tier) + its tier-specific config blob. */
export interface SystemMember {
  id?: string;
  target: string;              // native | docker | k8s
  app: string;
  role_in_system?: string | null;
  config?: Record<string, unknown>;
  image?: string;              // convenience for a proposed docker member
  chart?: string;
}

export interface SystemSummary {
  id: string;
  name: string;
  description?: string | null;
  seed_agent_id?: string | null;
  edges: unknown[];
  member_count: number;
  created_at?: string | null;
  members?: SystemMember[];
}

export interface ProposedSystem {
  proposed: boolean;
  seed: { id: string; name: string };
  name: string;
  members: SystemMember[];
  member_count: number;
  edges: { from: string; to: string; kind?: string }[];
  note?: string;
}

export interface CloneResult {
  sandbox_prefix: string;
  dry_run: boolean;
  source_resource_count?: number;
  secret_count?: number;
  secret_refs?: { key: string; scope: string; handle: string }[];
  materialize?: { changed_count?: number; docker?: { name: string; command?: string }[] };
}

export interface RehearsalResult {
  passed: boolean;
  sandbox_prefix?: string;
  change?: unknown;
  checks: { container?: string; member?: string; running?: boolean; health?: string | null; passed?: boolean; error?: string }[];
  torn_down?: string[];
}

export interface PromoteResult {
  promoted: boolean;
  reason?: string;
  applied_count?: number;
  change_set?: { member: string; from_image?: string; to_image?: string; ok?: boolean; error?: string }[];
  rolled_back?: string[];
  rehearsal?: RehearsalResult;
}

/** Systems = the unit above a host (apps + wiring): propose from live state,
 * persist, clone into a sandbox, rehearse a change, promote to prod. */
@Injectable({ providedIn: 'root' })
export class SystemsService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/systems`;

  list() { return this.http.get<{ systems: SystemSummary[]; count: number }>(this.base); }
  get(id: string) { return this.http.get<SystemSummary>(`${this.base}/${id}`); }
  propose(agentId: string, name = '') {
    return this.http.get<ProposedSystem>(`${this.base}/propose`, { params: { agent_id: agentId, ...(name ? { name } : {}) } });
  }
  create(body: { name: string; description?: string; seed_agent_id?: string; members: SystemMember[]; edges: unknown[] }) {
    return this.http.post<SystemSummary>(this.base, body);
  }
  remove(id: string) { return this.http.delete<{ deleted: string }>(`${this.base}/${id}`); }
  clone(id: string, body: { target_agent_id: string; dry_run: boolean }) {
    return this.http.post<CloneResult>(`${this.base}/${id}/clone`, body);
  }
  rehearse(id: string, body: { target_agent_id: string; image_overrides?: Record<string, string>; teardown?: boolean }) {
    return this.http.post<RehearsalResult>(`${this.base}/${id}/rehearse`, body);
  }
  promote(id: string, body: { target_agent_id: string; image_overrides: Record<string, string>; rehearse_first?: boolean; dry_run?: boolean }) {
    return this.http.post<PromoteResult>(`${this.base}/${id}/promote`, body);
  }
}
