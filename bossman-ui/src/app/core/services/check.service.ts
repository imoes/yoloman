import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import {
  CheckAssignment,
  CheckCatalogEntry,
  CreateCheckAssignment,
  DiscoveryProposal,
  EffectiveCheck,
} from '../models/check.model';

/** REST client for the check library + assignments (Block G9). */
@Injectable({ providedIn: 'root' })
export class CheckService {
  private http = inject(HttpClient);
  private base = environment.apiUrl;

  /** Every check in checks.d (catalog). */
  listChecks() {
    return this.http.get<{ checks: CheckCatalogEntry[] }>(`${this.base}/checks`);
  }

  getCheck(name: string) {
    return this.http.get<{ name: string; metadata: Record<string, unknown>; star_code: string }>(
      `${this.base}/checks/${encodeURIComponent(name)}`,
    );
  }

  /** The checks that effectively apply to a host (resolved inheritance). */
  effectiveHostChecks(agentId: string) {
    return this.http.get<{ agent_id: string; checks: EffectiveCheck[] }>(`${this.base}/agents/${agentId}/checks`);
  }

  /** Direct assignments on a scope target (host/group/OU). */
  listAssignments(filter: { agent_id?: string; ou_id?: string; host_group_id?: string }) {
    let params = new HttpParams();
    for (const [k, v] of Object.entries(filter)) if (v) params = params.set(k, v);
    return this.http.get<{ assignments: CheckAssignment[] }>(`${this.base}/check-assignments`, { params });
  }

  createAssignment(body: CreateCheckAssignment) {
    return this.http.post<CheckAssignment>(`${this.base}/check-assignments`, body);
  }

  updateAssignment(id: string, parameters: Record<string, unknown>) {
    return this.http.patch<CheckAssignment>(`${this.base}/check-assignments/${id}`, { parameters });
  }

  deleteAssignment(id: string) {
    return this.http.delete<void>(`${this.base}/check-assignments/${id}`);
  }

  /** Block G9-P3c: run auto-discovery on a host (checks' _discover mode). */
  discover(agentId: string, checkNames?: string[]) {
    return this.http.post<{ agent_id: string; candidates: number; proposals: DiscoveryProposal[] }>(
      `${this.base}/agents/${agentId}/discover`,
      checkNames ? { check_names: checkNames } : {},
    );
  }

  /** Turn accepted proposals into host-scoped assignments. */
  applyDiscovery(agentId: string, assign: { check_name: string; item?: string; parameters?: Record<string, unknown> }[]) {
    return this.http.post<{ agent_id: string; assigned: string[] }>(
      `${this.base}/agents/${agentId}/discover/apply`,
      { assign },
    );
  }

  /** Whether a check ships a provisioning recipe + the admin params to collect. */
  provisioning(name: string) {
    return this.http.get<{
      available: boolean;
      title?: string;
      description?: string;
      admin_params?: { name: string; description: string; required: boolean; secret: boolean }[];
    }>(`${this.base}/checks/${encodeURIComponent(name)}/provisioning`);
  }

  /** Run a check's provisioning recipe (create the monitoring account) then
   * assign the check to the host with the generated credential. */
  provision(agentId: string, name: string, adminParams: Record<string, string>, extraParams?: Record<string, unknown>) {
    return this.http.post<{ assignment: unknown; provisioned: boolean }>(
      `${this.base}/agents/${agentId}/checks/${encodeURIComponent(name)}/provision`,
      { admin_params: adminParams, extra_params: extraParams || {} },
    );
  }
}
