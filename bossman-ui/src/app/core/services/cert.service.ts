import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

export type CertStatus = 'ok' | 'warning' | 'critical' | 'expired' | 'error' | 'unknown';

export interface CertTarget {
  id: string;
  name: string;
  enabled: boolean;
  kind: 'tls' | 'manual';
  endpoint: string;
  warn_days: number;
  crit_days: number;
  subject: string | null;
  issuer: string | null;
  serial: string | null;
  not_before: string | null;
  not_after: string | null;
  sans: string[];
  days_left: number | null;
  status: CertStatus;
  last_error: string | null;
  last_checked_at: string | null;
}

export interface CertTargetInput {
  name: string;
  enabled: boolean;
  kind: 'tls' | 'manual';
  endpoint: string;
  warn_days: number;
  crit_days: number;
  not_after?: string | null;
}

export interface CertSummary {
  total: number;
  by_status: Partial<Record<CertStatus, number>>;
}

@Injectable({ providedIn: 'root' })
export class CertService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/cert-targets`;

  list() { return this.http.get<CertTarget[]>(this.base); }
  summary() { return this.http.get<CertSummary>(`${this.base}/summary`); }
  create(body: CertTargetInput) { return this.http.post<CertTarget>(this.base, body); }
  update(id: string, body: CertTargetInput) { return this.http.put<CertTarget>(`${this.base}/${id}`, body); }
  check(id: string) { return this.http.post<CertTarget>(`${this.base}/${id}/check`, {}); }
  remove(id: string) { return this.http.delete<void>(`${this.base}/${id}`); }
}
