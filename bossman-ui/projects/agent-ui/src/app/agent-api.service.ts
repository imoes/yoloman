import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpInterceptorFn } from '@angular/common/http';
import { Observable } from 'rxjs';

/** The bearer token the standalone UI uses against the agent's own /api/v1.
 * Stored in localStorage (the agent's token or a PAM session token), attached
 * to every request by authInterceptor. Empty = unauthenticated (dev). */
export const TOKEN_KEY = 'agent_ui_token';

export const authInterceptor: HttpInterceptorFn = (req, next) => {
  const tok = localStorage.getItem(TOKEN_KEY);
  if (tok && req.url.startsWith('/api/')) {
    req = req.clone({ setHeaders: { Authorization: `Bearer ${tok}` } });
  }
  return next(req);
};

// ---- Agent API shapes (subset used by the standalone UI) ----
export interface Process {
  pid: number;
  user: string;
  comm: string;
  command: string;
  cpu_percent: number;
  rss_kib: number;
  num_threads: number;
  state: string;
}
export interface ProcessesResponse { processes: Process[]; count: number; sample_window_ms: number; }
export interface ToolInfo { name: string; kind?: string; writes?: boolean; }

/** One runbook step as the agent's /api/v1/runbook/run expects. */
export interface RunbookStep {
  name: string;
  module?: string;
  params?: Record<string, unknown>;
  assert?: { that: string[]; fail_msg?: string };
  when?: string;
  register?: string;
  loop?: unknown;
}
export interface Runbook { name: string; params?: Record<string, unknown>; steps: RunbookStep[]; }
export interface StepResult { index: number; name: string; module?: string; changed: boolean; skipped?: boolean; msg?: string; data?: unknown; error?: string; }
export interface RunResult { runbook: string; status: string; changed: boolean; steps: StepResult[]; }

/** Talks to the agent's OWN REST API, same-origin (the UI is served by the
 * agent at /ui, so /api/v1/... hits the very host it manages). No Bossman. */
@Injectable({ providedIn: 'root' })
export class AgentApi {
  private http = inject(HttpClient);
  private base = '/api/v1';

  processes(limit = 0): Observable<ProcessesResponse> {
    let url = `${this.base}/processes`;
    if (limit > 0) url += `?limit=${limit}`;
    return this.http.get<ProcessesResponse>(url);
  }

  tools(): Observable<{ tools: ToolInfo[] }> {
    return this.http.get<{ tools: ToolInfo[] }>(`${this.base}/tools`);
  }

  metricNames(): Observable<{ metrics: string[] }> {
    return this.http.get<{ metrics: string[] }>(`${this.base}/metrics`);
  }

  metricSeries(metric: string): Observable<{ points: { time: string; value: number }[] }> {
    return this.http.get<{ points: { time: string; value: number }[] }>(`${this.base}/metrics/${encodeURIComponent(metric)}`);
  }

  runRunbook(runbook: Runbook, dryRun: boolean): Observable<RunResult> {
    return this.http.post<RunResult>(`${this.base}/runbook/run`, { runbook, dry_run: dryRun });
  }

  // ---- Server-as-a-document (state) ----
  stateObserved(): Observable<ObservedState> {
    return this.http.get<ObservedState>(`${this.base}/state/observed`);
  }
  stateGenerations(): Observable<{ generations: StateGeneration[] }> {
    return this.http.get<{ generations: StateGeneration[] }>(`${this.base}/state/generations`);
  }
  stateRollback(generation: number, dryRun: boolean): Observable<StateApplyResult> {
    return this.http.post<StateApplyResult>(`${this.base}/state/rollback`, { generation, dry_run: dryRun });
  }
}

export interface ObservedResource {
  type: string;
  path: string;
  format: string;
  separator?: string;
  values?: Record<string, unknown>;
  sha256?: string;
  size?: number;
  error?: string;
}
export interface ObservedState {
  generated_at: string;
  services: unknown;
  config: ObservedResource[];
}
export interface StateGeneration {
  number: number;
  applied_at: string;
  hash: string;
  resources: number;
}
export interface StateResourceChange {
  type: string;
  path: string;
  action: string;
  changed?: Record<string, [unknown, unknown]>;
  error?: string;
}
export interface StatePlan {
  changes: StateResourceChange[];
  changed_count: number;
}
export interface StateApplyResult {
  plan: StatePlan;
  generation: number;
  rolled_back_to?: number;
  dry_run: boolean;
}
