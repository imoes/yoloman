import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { RelationshipsResponse } from '../models/edge.model';

@Injectable({ providedIn: 'root' })
export class RelationshipService {
  private http = inject(HttpClient);

  /** What a host talks to, GROUPED by (process, destination).
   *
   * The endpoint used to return every raw edge — 5.46 MB on one measured host, because ephemeral-port
   * traffic makes one permanent row per port. `raw` asks for the underlying edges when a caller genuinely
   * wants connections rather than relationships; both are capped and both report the totals, so a partial
   * answer says that it is one. */
  list(agentId?: string, opts?: { raw?: boolean; limit?: number }) {
    const q = new URLSearchParams();
    if (agentId) q.set('agent_id', agentId);
    if (opts?.raw) q.set('raw', 'true');
    if (opts?.limit) q.set('limit', String(opts.limit));
    const qs = q.toString();
    return this.http.get<RelationshipsResponse>(`${environment.apiUrl}/relationships${qs ? '?' + qs : ''}`);
  }
}
