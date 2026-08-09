import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { GroupPolicyReport, HostGroup, HostGroupInput } from '../models/host-group.model';

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

  /** Re-scope a group to another OU (palette drag-to-link). */
  patchOu(id: string, ouId: string) {
    return this.http.patch<HostGroup>(`${this.base}/${id}`, { ou_id: ouId });
  }

  delete(id: string) {
    return this.http.delete<void>(`${this.base}/${id}`);
  }

  replaceMembers(id: string, agentIds: string[]) {
    return this.http.put<HostGroup>(`${this.base}/${id}/members`, { agent_ids: agentIds });
  }

  /** Block O3: which policies apply to this group's members (read-only). */
  policyReport(id: string) {
    return this.http.get<GroupPolicyReport>(`${this.base}/${id}/policy-report`);
  }
}
