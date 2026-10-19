import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { environment } from '../../../environments/environment';

export interface AuditEntry {
  id: number;
  at: string;
  actor: string;
  actor_kind: string | null;
  action: string;
  category: string;
  method: string | null;
  path: string | null;
  target: string | null;
  status: 'ok' | 'failed';
  status_code: number | null;
  source_ip: string | null;
  detail: Record<string, unknown>;
}

export interface AuditStats {
  total: number;
  failed: number;
  by_category: Record<string, number>;
}

export interface AuditFilter {
  actor?: string;
  category?: string;
  status?: string;
  q?: string;
  limit?: number;
}

@Injectable({ providedIn: 'root' })
export class AuditService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/audit`;

  private params(f: AuditFilter): HttpParams {
    let p = new HttpParams();
    for (const [k, v] of Object.entries(f)) {
      if (v !== undefined && v !== null && v !== '') p = p.set(k, String(v));
    }
    return p;
  }

  list(f: AuditFilter = {}) {
    return this.http.get<AuditEntry[]>(this.base, { params: this.params(f) });
  }
  stats() { return this.http.get<AuditStats>(`${this.base}/stats`); }

  /** The full filtered trail as CSV text (server-generated; the same filters as list()). Fetched via HttpClient so the
   *  bearer header is attached — not a bare link — then handed to the browser as a download by the caller. */
  exportCsv(f: AuditFilter = {}) {
    return this.http.get(`${this.base}/export.csv`, { params: this.params(f), responseType: 'text' });
  }
}
