import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders, HttpParams } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { NotificationLogEntry, NotificationRule, NotificationRuleInput, TimePeriod, TimePeriodInput, TimePeriodUsage } from '../models/notification.model';

/** REST client for notification rules + the send log (Block H8). */
@Injectable({ providedIn: 'root' })
export class NotificationService {
  private http = inject(HttpClient);
  private base = environment.apiUrl;

  listRules() {
    return this.http.get<NotificationRule[]>(`${this.base}/notification-rules`);
  }

  createRule(body: NotificationRuleInput) {
    return this.http.post<NotificationRule>(`${this.base}/notification-rules`, body);
  }

  updateRule(id: string, body: NotificationRuleInput) {
    return this.http.put<NotificationRule>(`${this.base}/notification-rules/${id}`, body);
  }

  patchRule(id: string, patch: { enforced?: boolean; enabled?: boolean; link_order?: number; ou_id?: string }) {
    return this.http.patch<NotificationRule>(`${this.base}/notification-rules/${id}`, patch);
  }

  deleteRule(id: string) {
    return this.http.delete<void>(`${this.base}/notification-rules/${id}`);
  }

  log(limit = 100) {
    const params = new HttpParams().set('limit', String(limit));
    return this.http.get<NotificationLogEntry[]>(`${this.base}/notifications`, { params });
  }

  /** L4: the selectable notification windows. `active_now` is evaluated server-side per
   * request, so this is also the "is my window open right now" answer. */
  timePeriods() {
    return this.http.get<TimePeriod[]>(`${this.base}/time-periods`);
  }

  createTimePeriod(body: TimePeriodInput) {
    return this.http.post<TimePeriod>(`${this.base}/time-periods`, body);
  }

  /** `version` travels as If-Match — see api/etag.py; without it the last writer wins
   * unnoticed. */
  updateTimePeriod(id: string, body: TimePeriodInput, version: string) {
    const headers = version ? new HttpHeaders({ 'If-Match': version }) : undefined;
    return this.http.put<TimePeriod>(`${this.base}/time-periods/${id}`, body, headers ? { headers } : {});
  }

  /** Refused (409) while another period excludes this one: a dangling exclude would make the
   * referencing period unevaluable, and the dispatcher then treats it as unrestricted — the
   * exclusion would quietly stop applying. Rules pointing at it widen back to "always". */
  deleteTimePeriod(id: string) {
    return this.http.delete<void>(`${this.base}/time-periods/${id}`);
  }

  /** Which notification rules use this window, and which periods exclude it. */
  timePeriodUsage(id: string) {
    return this.http.get<TimePeriodUsage>(`${this.base}/time-periods/${id}/usage`);
  }
}
