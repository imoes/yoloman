import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { HostEdge } from '../models/edge.model';

@Injectable({ providedIn: 'root' })
export class RelationshipService {
  private http = inject(HttpClient);

  list(agentId?: string) {
    const url = agentId
      ? `${environment.apiUrl}/relationships?agent_id=${encodeURIComponent(agentId)}`
      : `${environment.apiUrl}/relationships`;
    return this.http.get<HostEdge[]>(url);
  }
}
