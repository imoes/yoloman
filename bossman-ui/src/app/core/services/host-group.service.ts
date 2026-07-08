import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { HostGroup, HostGroupInput } from '../models/host-group.model';

/** REST client for first-class host groups (Block L1) — mirrors
 * MonitoringService's shape. */
@Injectable({ providedIn: 'root' })
export class HostGroupService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/host-groups`;

  list() {
    return this.http.get<HostGroup[]>(this.base);
  }

  create(body: HostGroupInput) {
    return this.http.post<HostGroup>(this.base, body);
  }

  update(id: string, body: HostGroupInput) {
    return this.http.put<HostGroup>(`${this.base}/${id}`, body);
  }

  delete(id: string) {
    return this.http.delete<void>(`${this.base}/${id}`);
  }

  replaceMembers(id: string, agentIds: string[]) {
    return this.http.put<HostGroup>(`${this.base}/${id}/members`, { agent_ids: agentIds });
  }
}
