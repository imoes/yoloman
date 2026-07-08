import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { OUNode, OUNodeInput, OUObject } from '../models/ou.model';

/** REST client for the OU tree (Block L1) — mirrors MonitoringService's shape. */
@Injectable({ providedIn: 'root' })
export class OuService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/ou`;

  list() {
    return this.http.get<OUNode[]>(this.base);
  }

  create(body: OUNodeInput) {
    return this.http.post<OUNode>(this.base, body);
  }

  delete(id: string) {
    return this.http.delete<void>(`${this.base}/${id}`);
  }

  ancestry(id: string) {
    return this.http.get<OUNode[]>(`${this.base}/${id}/ancestry`);
  }

  /** Block L3a: every policy object attached directly to this OU (the tree's child list). */
  objects(id: string) {
    return this.http.get<OUObject[]>(`${this.base}/${id}/objects`);
  }

  /** Block L3a: toggle GPO "Block Inheritance" on an OU. */
  setBlockInheritance(id: string, blockInheritance: boolean) {
    return this.http.patch<OUNode>(`${this.base}/${id}`, { block_inheritance: blockInheritance });
  }

  assignAgent(agentId: string, ouId: string | null) {
    return this.http.put<OUNode | null>(`${environment.apiUrl}/agents/${agentId}/ou`, { ou_id: ouId });
  }
}
