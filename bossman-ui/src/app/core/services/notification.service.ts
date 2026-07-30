import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { NotificationLogEntry, NotificationRule, NotificationRuleInput, TimePeriod } from '../models/notification.model';

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

  /** L4: the selectable notification windows. */
  timePeriods() {
    return this.http.get<TimePeriod[]>(`${this.base}/time-periods`);
  }
}
