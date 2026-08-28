import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { environment } from '../../../environments/environment';

/**
 * THE RESULT LOG — what HOSTS did, and what came back.
 *
 * Not the audit log, and the difference is worth keeping in mind while reading either: the audit log records
 * what somebody asked THIS SERVER to do (an API call, a login, a policy change); this records what a HOST
 * actually did — the module, the exit code, the plan it produced for itself, the target's own refusal text.
 * A request and its effect are two facts, and only the second one answers "did that install work".
 */
export interface OperationRecord {
  id: string;
  /** The agent's own record id — a stable handle to point at one call. */
  record_id: string | null;
  agent_id: string;
  host: string | null;
  boot_id: string;
  seq: number;
  module: string;
  outcome: OperationOutcome;
  dry_run: boolean;
  changed: boolean | null;
  params: Record<string, unknown> | null;
  identity: string | null;
  started_at: string | null;
  duration_ms: number | null;
  message: string | null;
  /** The module's own data block, verbatim: the evidence behind the verdict. */
  evidence: unknown;
  error: string | null;
  collected_at: string | null;
}

/**
 * The fixed vocabulary. Each value is a different thing that happened, and no two may be shown as one:
 * `planned` is a dry run (a preview, nothing was done), `refused` is the host saying no, `error` is our agent
 * breaking, and `timed-out` MAY HAVE COMPLETED — showing it as a failure is the one mistake this list exists
 * to prevent. `gap` is Bossman's own marker for records lost from an agent's ring before collection.
 */
export type OperationOutcome =
  | 'changed' | 'unchanged' | 'planned' | 'refused' | 'error' | 'timed-out' | 'unknown-module' | 'gap';

export interface OperationsPage {
  count: number;
  query: Record<string, unknown>;
  outcomes: OperationOutcome[];
  operations: OperationRecord[];
  /** Per-host answer only: which of the agent's own sequence numbers we hold, per agent process. */
  collected_range?: { boot_id: string; first_seq: number; last_seq: number; records: number }[];
  host?: string;
}

export interface OperationsFilter {
  host?: string;
  agent_id?: string;
  module?: string;
  outcome?: string;
  since?: string;
  changed_only?: boolean;
  limit?: number;
}

@Injectable({ providedIn: 'root' })
export class OperationsService {
  private http = inject(HttpClient);

  list(f: OperationsFilter = {}) {
    let p = new HttpParams();
    for (const [k, v] of Object.entries(f)) {
      if (v !== undefined && v !== null && v !== '' && v !== false) p = p.set(k, String(v));
    }
    return this.http.get<OperationsPage>(`${environment.apiUrl}/operations`, { params: p });
  }

  forAgent(agentId: string, f: OperationsFilter = {}) {
    let p = new HttpParams();
    for (const [k, v] of Object.entries(f)) {
      if (v !== undefined && v !== null && v !== '' && v !== false) p = p.set(k, String(v));
    }
    return this.http.get<OperationsPage>(`${environment.apiUrl}/agents/${agentId}/operations`, { params: p });
  }
}
