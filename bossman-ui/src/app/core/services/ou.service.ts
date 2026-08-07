import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { OUNode, OUNodeInput, OUObject } from '../models/ou.model';

/** RSoP report for a scope — matches bossman/api/ou.py PolicyReportOut. */
export interface PolicyReportRow {
  kind: 'config' | 'threshold' | 'plan' | 'notification';
  label: string;
  detail: string;
  origin: string;
  enforced: boolean;
}
export interface PolicyReport {
  scope_type: string;
  scope_label: string;
  variables: { key: string; value: string; origin: string }[];
  rows: PolicyReportRow[];
}

/** REST client for the OU tree (Block L1) — mirrors MonitoringService's shape. */
@Injectable({ providedIn: 'root' })
export class OuService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/ou`;

  list() {
    return this.http.get<OUNode[]>(this.base);
  }

  /** Resultant Set of Policy for a scope — what applies here (own + inherited)
   * plus variables and where each rule comes from. Backs the right-hand report. */
  policyReport(scopeType: 'ou' | 'site' | 'group', scopeId: string) {
    return this.http.get<PolicyReport>(
      `${environment.apiUrl}/policy-report?scope_type=${scopeType}&scope_id=${scopeId}`);
  }

  create(body: OUNodeInput) {
    return this.http.post<OUNode>(this.base, body);
  }

  delete(id: string) {
    return this.http.delete<void>(`${this.base}/${id}`);
  }

  /** Block K4 — remove an OU config policy (stops distributing it; member
   * hosts keep the last-applied file until re-synced). */
  deleteConfigPolicy(id: string) {
    return this.http.delete<void>(`${environment.apiUrl}/config-policies/${id}`);
  }

  /** Agents in the OU's subtree — the Policy-console gpedit uses the first
   * reachable one as its settings catalog ("Host A = Host B"). */
  members(ouId: string) {
    return this.http.get<{ id: string; name: string; address: string | null; ou_id: string | null }[]>(
      `${this.base}/${ouId}/members`,
    );
  }

  /** Config policies WITH their values documents at one scope (the objects
   * list only carries a label) — feeds the Policy-console gpedit editor. */
  listConfigPolicies(scope: { ouId?: string; groupId?: string; siteId?: string; unlinked?: boolean }) {
    const q = scope.ouId ? `scope_ou_id=${scope.ouId}`
      : scope.siteId ? `site_id=${scope.siteId}`
      : scope.unlinked ? `unlinked=true`
      : `host_group_id=${scope.groupId}`;
    return this.http.get<
      { id: string; scope_ou_id: string | null; host_group_id: string | null; site_id: string | null; path: string; type: string; format: string | null; separator: string | null; values: Record<string, unknown>; template: string | null }[]
    >(`${environment.apiUrl}/config-policies?${q}`);
  }

  /** GPO "Not configured" at OU/group/site scope: stop managing one key. */
  unsetConfigPolicyKey(body: { scope_ou_id?: string; host_group_id?: string; site_id?: string; path: string; key: string }) {
    return this.http.post<{ unset: boolean }>(`${environment.apiUrl}/config-policies/unset`, body);
  }

  /** Set (or clear, with {}) the variables on an OU — used by the tree's
   * Variables object; clearing removes the object. */
  setOuVars(ouId: string, vars: Record<string, unknown>) {
    return this.http.put<unknown>(`${environment.apiUrl}/scope-vars`, { scope_type: 'ou', ou_id: ouId, vars });
  }

  /** Move a placed config policy to another OU/group/site scope. */
  rescopeConfigPolicy(id: string, body: { scope_ou_id?: string; host_group_id?: string; site_id?: string }) {
    return this.http.patch<{ id: string }>(`${environment.apiUrl}/config-policies/${id}`, body);
  }

  /** Block K4 — author a config-value policy at OU/group scope (gpedit's
   * "add a setting") and converge every reachable member host. Exactly one of
   * ouId / hostGroupId is set. `values` is the desired key→value document
   * (a null value enforces the key's absence). */
  createConfigPolicy(body: {
    scope_ou_id?: string;
    host_group_id?: string;
    site_id?: string;
    path: string;
    format: string;
    values: Record<string, unknown>;
    dry_run?: boolean;
  }) {
    return this.http.post<{ scope: string; applied_hosts: string[]; skipped_hosts: string[]; dry_run: boolean }>(
      `${environment.apiUrl}/config-policies`,
      body,
    );
  }

  ancestry(id: string) {
    return this.http.get<OUNode[]>(`${this.base}/${id}/ancestry`);
  }

  /** Block L3a: every policy object attached directly to this OU (the tree's child list). */
  objects(id: string) {
    return this.http.get<OUObject[]>(`${this.base}/${id}/objects`);
  }

  /** Block L3a: toggle GPO "Block Inheritance" on an OU. */
  setBlockInheritance(id: string, blockInheritance: boolean) {
    return this.http.patch<OUNode>(`${this.base}/${id}`, { block_inheritance: blockInheritance });
  }

  /** Block L3e: reparent an OU (drag-and-drop move). parentId=null moves it
   * to the forest root. The server rewrites the whole subtree's paths. */
  move(id: string, parentId: string | null) {
    return this.http.post<OUNode>(`${this.base}/${id}/move`, { parent_id: parentId });
  }

  assignAgent(agentId: string, ouId: string | null) {
    return this.http.put<OUNode | null>(`${environment.apiUrl}/agents/${agentId}/ou`, { ou_id: ouId });
  }
}
