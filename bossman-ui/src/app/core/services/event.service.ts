import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { environment } from '../../../environments/environment';

/** A passively-received event (syslog / SNMP trap) — mirrors api/events.py. */
export interface EventItem {
  id: string;
  received_at: string;
  kind: 'syslog' | 'snmptrap';
  source_ip: string;
  host_name: string | null;
  severity: number;
  severity_name: string;
  facility: number | null;
  app: string | null;
  message: string;
  acknowledged: boolean;
}

export interface EventStats { total: number; unacked: number; urgent: number; }

@Injectable({ providedIn: 'root' })
export class EventService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/events`;

  list(filter: { kind?: string; host?: string; max_severity?: number; unacked?: boolean; limit?: number } = {}) {
    let p = new HttpParams();
    for (const [k, v] of Object.entries(filter)) if (v !== undefined && v !== '' && v !== false) p = p.set(k, String(v));
    return this.http.get<EventItem[]>(this.base, { params: p });
  }
  stats() { return this.http.get<EventStats>(`${this.base}/stats`); }
  ack(id: string) { return this.http.post<EventItem>(`${this.base}/${id}/ack`, {}); }
}
