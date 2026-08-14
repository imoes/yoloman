import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { EventRule, EventRuleInput, EventRun } from '../models/event-rule.model';

/** REST client for event rules and their runs.
 *
 * The endpoints are still named `remediation-*`; the rename to "event rule" is a separate step
 * (docs/event-handling.md). Keeping the URLs untouched here means a naming change cannot be
 * confused with a functional one when it happens. */
@Injectable({ providedIn: 'root' })
export class EventRuleService {
  private http = inject(HttpClient);
  private base = environment.apiUrl;

  list() {
    return this.http.get<EventRule[]>(`${this.base}/remediation-policies`);
  }

  create(body: EventRuleInput) {
    return this.http.post<EventRule>(`${this.base}/remediation-policies`, body);
  }

  /** Edits in place. Delete-and-recreate would cut every past run loose from the rule that
   * caused it (remediation_runs.policy_id is ON DELETE SET NULL), which is why this endpoint had
   * to exist before an editor could. */
  update(id: string, body: EventRuleInput) {
    return this.http.put<EventRule>(`${this.base}/remediation-policies/${id}`, body);
  }

  delete(id: string) {
    return this.http.delete<void>(`${this.base}/remediation-policies/${id}`);
  }

  /** The run history, or just the pending queue with status='pending'. */
  runs(status?: string, limit = 100) {
    let params = new HttpParams().set('limit', String(limit));
    if (status) params = params.set('status', status);
    return this.http.get<EventRun[]>(`${this.base}/remediation-runs`, { params });
  }

  /** Apply a pending proposal now — the manual execution path. */
  apply(runId: string) {
    return this.http.post<Record<string, unknown>>(`${this.base}/remediation-runs/${runId}/apply`, {});
  }

  dismiss(runId: string) {
    return this.http.post<void>(`${this.base}/remediation-runs/${runId}/dismiss`, {});
  }

  /** Run every rule matching (host, check) right now, bypassing the rate limit — an
   * operator-initiated heal. */
  triggerNow(agentId: string, service: string) {
    const params = new HttpParams().set('service', service);
    return this.http.post<Record<string, unknown>>(
      `${this.base}/agents/${agentId}/remediate`, {}, { params },
    );
  }
}
