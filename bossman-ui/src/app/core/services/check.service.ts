import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { Observable, timer } from 'rxjs';
import { switchMap, takeWhile } from 'rxjs/operators';
import { environment } from '../../../environments/environment';
import {
  CheckAssignment,
  CheckCatalogEntry,
  CreateCheckAssignment,
  DiscoveryProposal,
  EffectiveCheck,
} from '../models/check.model';

/** A discovery job's progress, polled while it runs; `result` is present only on the final (done)
 *  emission. `percent` is server-computed and caps below 100 until done. */
export interface DiscoveryProgress {
  job_id: string;
  total: number;
  completed: number;
  percent: number;
  done: boolean;
  error?: string;
  result?: { agent_id: string; candidates: number; proposals: DiscoveryProposal[]; reconciled?: boolean };
}

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

  /** Run auto-discovery on a host, emitting progress until it completes.
   *
   * Discovery is a background job now (~1400 checks, seconds long): the POST returns a job id, and this
   * polls the progress endpoint every 500 ms, emitting each snapshot so the caller can drive a percent
   * bar. The final emission has done=true and carries `result` (proposals + transitions). */
  discover(agentId: string, checkNames?: string[]): Observable<DiscoveryProgress> {
    return this.http
      .post<{ job_id: string; total: number; candidates: number }>(
        `${this.base}/agents/${agentId}/discover`,
        checkNames ? { check_names: checkNames } : {},
      )
      .pipe(
        switchMap(({ job_id }) =>
          timer(0, 500).pipe(
            switchMap(() =>
              this.http.get<DiscoveryProgress>(`${this.base}/agents/${agentId}/discover/progress/${job_id}`),
            ),
            // Emit the done snapshot too (inclusive), then complete.
            takeWhile((p) => !p.done, true),
          ),
        ),
      );
  }

  /** Turn accepted proposals into host-scoped assignments. */
  applyDiscovery(agentId: string, assign: { check_name: string; item?: string; parameters?: Record<string, unknown> }[]) {
    return this.http.post<{ agent_id: string; assigned: string[] }>(
      `${this.base}/agents/${agentId}/discover/apply`,
      { assign },
    );
  }

  /** What discovery KNOWS about a host, per lifecycle state — the persisted result
   *  (Checkmk's autochecks), not the monitoring state. Every state the model can
   *  hold is returned here, which is why the view can show all four instead of
   *  letting a vanished service disappear silently. */
  discoveredServices(agentId: string) {
    return this.http.get<{
      agent_id: string;
      counts: Record<string, number>;
      services: { check_name: string; item: string | null; state: string;
                  first_seen?: string; last_seen?: string; parameters?: Record<string, unknown> }[];
    }>(`${this.base}/agents/${agentId}/discovered-services`);
  }

  /** Decide what happens to discovered services. `ignore` is remembered (later runs
   *  stop offering it); `remove` stops monitoring — and for a VANISHED service it
   *  stops tracking it altogether. */
  decideDiscovery(agentId: string, body: {
    accept?: { check_name: string; item?: string; parameters?: Record<string, unknown> }[];
    ignore?: { check_name: string; item?: string }[];
    remove?: { check_name: string; item?: string }[];
  }) {
    return this.http.post<{ agent_id: string; accepted?: number; ignored?: number; removed?: number }>(
      `${this.base}/agents/${agentId}/discover/apply`, body,
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
