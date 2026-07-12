import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { environment } from '../../../environments/environment';

export interface CveHost {
  agent_id: string;
  host: string;
  package: string;
  current_version: string;
  fixed_version: string;
}

export interface FleetCve {
  cve: string;
  severity: string;
  distro: string;
  hosts: CveHost[];
  host_count: number;
}

export interface CveSummary {
  total_findings: number;
  distinct_cves: number;
  affected_hosts: number;
  by_severity: Record<string, number>;
  by_distro: Record<string, number>;
}

export interface CveFilters {
  severity?: string;
  distro?: string;
  agent_id?: string;
  fix_available?: boolean;
  q?: string;
}

/** Block 4-D — the fleet-wide CVE / security correlation API. */
@Injectable({ providedIn: 'root' })
export class SecurityService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/security`;

  summary() {
    return this.http.get<CveSummary>(`${this.base}/summary`);
  }

  cves(filters: CveFilters = {}) {
    let params = new HttpParams();
    for (const [k, v] of Object.entries(filters)) {
      if (v !== undefined && v !== null && v !== '') params = params.set(k, String(v));
    }
    return this.http.get<{ count: number; cves: FleetCve[] }>(`${this.base}/cves`, { params });
  }

  feedStatus() {
    return this.http.get<{ enabled: boolean; last_run_ok: boolean | null; last_error: string | null; counts: Record<string, number> }>(`${this.base}/feed-status`);
  }

  refresh() {
    return this.http.post<{ ok: boolean; counts: Record<string, number> }>(`${this.base}/refresh`, {});
  }

  /** Per-host: collect + correlate live, returns the host's CVEs. */
  hostCves(agentId: string) {
    return this.http.get<{ agent_id: string; count: number; cves: any[] }>(`${environment.apiUrl}/agents/${agentId}/cves`);
  }

  /** Bulk: apply (security) package updates to many hosts at once. */
  bulkUpdate(agentIds: string[], securityOnly = true, dryRun = true) {
    return this.http.post<BulkUpdateResult>(`${this.base}/bulk-update`, {
      agent_ids: agentIds,
      security_only: securityOnly,
      dry_run: dryRun,
    });
  }
}

export interface BulkUpdateHostResult {
  agent_id: string;
  host?: string;
  status: 'ok' | 'error' | 'forbidden' | 'unreachable' | 'not_found';
  error?: string;
  result?: unknown;
}
export interface BulkUpdateResult {
  dry_run: boolean;
  security_only: boolean;
  applied: number;
  results: BulkUpdateHostResult[];
}
