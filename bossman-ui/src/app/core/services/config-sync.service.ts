import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

export interface SyncStatus {
  enabled: boolean;
  interval_seconds: number;
  last_run_at: string | null;
  checked: number;
  pushed: number;
  failed: number;
  hosts_behind: number;
}
export interface SyncRunResult { checked: number; pushed: number; failed: number; }

@Injectable({ providedIn: 'root' })
export class ConfigSyncService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/config-sync`;

  status() { return this.http.get<SyncStatus>(`${this.base}/status`); }
  run() { return this.http.post<SyncRunResult>(`${this.base}/run`, {}); }
}
