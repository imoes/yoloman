import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

/** Matches bossman/api/deployments.py's request/response shapes. */
export interface DeploymentTargets {
  agent_ids?: string[];
  hostnames?: string[];
  group_ids?: string[];
  ou_ids?: string[];
  tags?: Record<string, string | null>;
}

export interface DeploymentRunRequest {
  kind: 'stored_plan' | 'runbook';
  prefix?: string;
  name?: string;
  runbook_nt?: string;
  runbook_name?: string;
  params?: Record<string, unknown>;
  dry_run: boolean;
  targets: DeploymentTargets;
}

export interface DeploymentHostResult {
  agent_id: string;
  agent_name: string;
  run_kind?: string;
  run_id?: string;
  status: string;
  changed?: boolean;
  error?: string;
}

export interface DeploymentRun {
  id: string;
  kind: string;
  target_ref: string;
  dry_run: boolean;
  status: 'running' | 'ok' | 'partial' | 'failed';
  total_hosts: number;
  ok_hosts: number;
  failed_hosts: number;
  unknown_hostnames: string[];
  requested_by: string | null;
  created_at: string | null;
  results?: DeploymentHostResult[];
}

@Injectable({ providedIn: 'root' })
export class DeploymentService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/deployments`;

  run(body: DeploymentRunRequest) {
    return this.http.post<DeploymentRun>(`${this.base}/run`, body);
  }

  list(limit = 50) {
    return this.http.get<{ deployments: DeploymentRun[] }>(`${this.base}?limit=${limit}`);
  }

  get(id: string) {
    return this.http.get<DeploymentRun>(`${this.base}/${id}`);
  }
}
