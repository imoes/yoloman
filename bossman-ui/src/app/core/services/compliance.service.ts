import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

export interface ComplianceViolation {
  kind: 'missing' | 'forbidden' | 'version';
  package: string;
  detail: string;
}
export interface ComplianceRule {
  id: string;
  name: string;
  enabled: boolean;
  scope_type: 'global' | 'host' | 'group' | 'ou';
  agent_id: string | null;
  host_group_id: string | null;
  ou_id: string | null;
  required: string[];
  forbidden: string[];
  severity: 'WARN' | 'CRIT';
  created_at: string;
  updated_at: string;
}
export interface ComplianceRuleInput {
  name: string;
  enabled: boolean;
  scope_type: 'global' | 'host' | 'group' | 'ou';
  agent_id: string | null;
  host_group_id: string | null;
  ou_id: string | null;
  required: string[];
  forbidden: string[];
  severity: 'WARN' | 'CRIT';
}
export interface ComplianceResult {
  agent_id: string;
  host_name: string;
  status: 'OK' | 'WARN' | 'CRIT';
  violations: ComplianceViolation[];
  evaluated_at: string;
}
export interface ComplianceSummary {
  rule: string;
  hosts: number;
  compliant: number;
  violating: number;
}

@Injectable({ providedIn: 'root' })
export class ComplianceService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/compliance-rules`;

  list() { return this.http.get<ComplianceRule[]>(this.base); }
  create(body: ComplianceRuleInput) { return this.http.post<ComplianceRule>(this.base, body); }
  update(id: string, body: ComplianceRuleInput) { return this.http.put<ComplianceRule>(`${this.base}/${id}`, body); }
  remove(id: string) { return this.http.delete<void>(`${this.base}/${id}`); }
  evaluate(id: string) { return this.http.post<ComplianceSummary>(`${this.base}/${id}/evaluate`, {}); }
  results(id: string) { return this.http.get<ComplianceResult[]>(`${this.base}/${id}/results`); }
}
