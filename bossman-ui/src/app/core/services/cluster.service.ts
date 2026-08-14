import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpHeaders } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { Cluster, ClusterInput } from '../models/cluster.model';

/** REST client for host clusters (/api/v1/clusters) — mirrors HostGroupService's shape. */
@Injectable({ providedIn: 'root' })
export class ClusterService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/clusters`;

  list() {
    return this.http.get<Cluster[]>(this.base);
  }

  create(body: ClusterInput) {
    return this.http.post<Cluster>(this.base, body);
  }

  /** `version` travels back as If-Match. Without it the API passes silently (see
   * api/etag.py's check_if_match) and the last writer wins unnoticed — with it, editing a
   * copy someone else already changed is a 412 the caller can explain. */
  update(id: string, body: ClusterInput, version: string) {
    const headers = version ? new HttpHeaders({ 'If-Match': version }) : undefined;
    return this.http.put<Cluster>(`${this.base}/${id}`, body, headers ? { headers } : {});
  }

  /** Removes the cluster host and its aggregated services. The NODES are untouched — they
   * are real hosts that existed before the cluster and keep their own services. */
  delete(id: string) {
    return this.http.delete<void>(`${this.base}/${id}`);
  }
}
