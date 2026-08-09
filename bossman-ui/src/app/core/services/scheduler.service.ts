import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

/** A recurring runbook run on a cron schedule (mirrors api/scheduler.py). */
export interface ScheduledJob {
  id: string;
  name: string;
  enabled: boolean;
  cron: string;
  runbook_name: string;
  scope_type: 'host' | 'group' | 'ou';
  agent_id?: string | null;
  host_group_id?: string | null;
  ou_id?: string | null;
  variables: Record<string, unknown>;
  dry_run: boolean;
  last_run_at?: string | null;
  last_status?: string | null;
  last_detail?: string | null;
  created_at?: string;
}

export type ScheduledJobInput = Omit<ScheduledJob, 'id' | 'last_run_at' | 'last_status' | 'last_detail' | 'created_at'>;

@Injectable({ providedIn: 'root' })
export class SchedulerService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/scheduled-jobs`;

  list() { return this.http.get<ScheduledJob[]>(this.base); }
  create(body: ScheduledJobInput) { return this.http.post<ScheduledJob>(this.base, body); }
  update(id: string, body: ScheduledJobInput) { return this.http.put<ScheduledJob>(`${this.base}/${id}`, body); }
  remove(id: string) { return this.http.delete<void>(`${this.base}/${id}`); }
  runNow(id: string) { return this.http.post<ScheduledJob>(`${this.base}/${id}/run-now`, {}); }
}
