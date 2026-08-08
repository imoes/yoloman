import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

export interface RolloutWave { name: string; agent_ids: string[]; }
export interface RolloutWaveResult {
  name: string; ok?: number; failed?: number; healthy?: boolean; health?: string;
  hosts?: { name: string; status: string }[]; error?: string;
}
export interface Rollout {
  id: string;
  name: string;
  runbook_name: string;
  dry_run: boolean;
  status: 'pending' | 'running' | 'paused' | 'done' | 'failed' | 'aborted';
  current_wave: number;
  waves: RolloutWave[];
  health_gate: { wait_seconds?: number; max_fail_pct?: number };
  progress: RolloutWaveResult[];
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
}

export interface RolloutInput {
  name: string;
  runbook_name: string;
  scope_type: 'host' | 'group' | 'ou' | 'global';
  agent_id?: string | null;
  host_group_id?: string | null;
  ou_id?: string | null;
  strategy: (number | string)[];
  /** AD-consistent waves: one wave per OU in the subtree (requires scope_type=ou). */
  by_ou?: boolean;
  canary?: boolean;
  /** Post-upgrade functional-test runbook; each wave passes only if it succeeds. */
  test_runbook_name?: string | null;
  /** One host per wave (blast radius 1). */
  one_at_a_time?: boolean;
  variables?: Record<string, unknown>;
  dry_run: boolean;
  wait_seconds: number;
  max_fail_pct: number;
}

@Injectable({ providedIn: 'root' })
export class RolloutService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/rollouts`;

  list() { return this.http.get<Rollout[]>(this.base); }
  get(id: string) { return this.http.get<Rollout>(`${this.base}/${id}`); }
  create(body: RolloutInput) { return this.http.post<Rollout>(this.base, body); }
  start(id: string) { return this.http.post<Rollout>(`${this.base}/${id}/start`, {}); }
  abort(id: string) { return this.http.post<Rollout>(`${this.base}/${id}/abort`, {}); }
  remove(id: string) { return this.http.delete<void>(`${this.base}/${id}`); }
}
