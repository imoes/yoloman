import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { Site, SiteInput } from '../models/site.model';

/** REST client for AD-style Sites (subnet-scoped policy targets). Base is
 * /policy-sites — /sites is already the fleet location facet (search.py). */
@Injectable({ providedIn: 'root' })
export class SiteService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/policy-sites`;

  list() {
    return this.http.get<Site[]>(this.base);
  }

  create(body: SiteInput) {
    return this.http.post<Site>(this.base, body);
  }

  update(id: string, body: SiteInput) {
    return this.http.put<Site>(`${this.base}/${id}`, body);
  }

  /** Re-scope a site to another OU (palette drag-to-link). */
  patchOu(id: string, ouId: string) {
    return this.http.patch<Site>(`${this.base}/${id}`, { ou_id: ouId });
  }

  delete(id: string) {
    return this.http.delete<void>(`${this.base}/${id}`);
  }

  /** Replace the site's subnets (the "Subnets…" editor). */
  replaceSubnets(id: string, cidrs: string[]) {
    return this.http.put<Site>(`${this.base}/${id}/subnets`, { cidrs });
  }
}
