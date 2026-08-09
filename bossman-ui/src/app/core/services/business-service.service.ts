import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

export interface BsMember {
  scope_type: 'global' | 'host' | 'group' | 'ou';
  agent_id?: string | null;
  host_group_id?: string | null;
  ou_id?: string | null;
  service_name?: string | null;
}
export interface BusinessService {
  id: string;
  name: string;
  description: string | null;
  enabled: boolean;
  members: BsMember[];
  logic: 'all' | 'any';
  status: 'OK' | 'WARN' | 'CRIT' | 'UNKNOWN';
  summary: {
    member_count?: number;
    counts?: Record<string, number>;
    members?: Array<{ service: string; agent_id: string; state: string }>;
  };
  last_evaluated_at: string | null;
}
export interface BusinessServiceInput {
  name: string;
  description?: string | null;
  enabled: boolean;
  members: BsMember[];
  logic: 'all' | 'any';
}

@Injectable({ providedIn: 'root' })
export class BusinessServiceService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/business-services`;

  list() { return this.http.get<BusinessService[]>(this.base); }
  create(body: BusinessServiceInput) { return this.http.post<BusinessService>(this.base, body); }
  update(id: string, body: BusinessServiceInput) { return this.http.put<BusinessService>(`${this.base}/${id}`, body); }
  evaluate(id: string) { return this.http.post<BusinessService>(`${this.base}/${id}/evaluate`, {}); }
  remove(id: string) { return this.http.delete<void>(`${this.base}/${id}`); }
}
