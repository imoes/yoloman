import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { Observable } from 'rxjs';
import { environment } from '../../../environments/environment';
import { Agent } from '../models/agent.model';
import {
  HostSearchResponse,
  MassAssignFacets,
  ServiceSearchResponse,
  UnifiedSearchResponse,
} from '../models/search.model';

/** REST client for the Checkmk-style fleet search (bossman/api/search.py).
 * Mirrors MonitoringService/AgentService's shape. */
@Injectable({ providedIn: 'root' })
export class SearchService {
  private http = inject(HttpClient);
  private base = environment.apiUrl;

  /** Grouped, capped live-dropdown preview. */
  unified(q: string, limit = 8): Observable<UnifiedSearchResponse> {
    const params = new HttpParams().set('q', q).set('limit', String(limit));
    return this.http.get<UnifiedSearchResponse>(`${this.base}/search`, { params });
  }

  /** Full paginated "hosts matching X" result view. */
  hosts(q: string, limit = 100, offset = 0): Observable<HostSearchResponse> {
    const params = new HttpParams().set('q', q).set('limit', String(limit)).set('offset', String(offset));
    return this.http.get<HostSearchResponse>(`${this.base}/search/hosts`, { params });
  }

  /** Full paginated "service-checks matching X" result view. */
  services(q: string, limit = 100, offset = 0): Observable<ServiceSearchResponse> {
    const params = new HttpParams().set('q', q).set('limit', String(limit)).set('offset', String(offset));
    return this.http.get<ServiceSearchResponse>(`${this.base}/search/services`, { params });
  }

  /** Bulk-assign criticality / site / tags across selected hosts. */
  bulkAssignFacets(body: MassAssignFacets): Observable<Agent[]> {
    return this.http.post<Agent[]>(`${this.base}/agents/mass-update/facets`, body);
  }

  /** Distinct tag keys → values across the fleet (tag: autocomplete). */
  tags(): Observable<{ tags: Record<string, string[]> }> {
    return this.http.get<{ tags: Record<string, string[]> }>(`${this.base}/tags`);
  }

  /** Distinct site values across the fleet (site: autocomplete). */
  sites(): Observable<{ sites: string[] }> {
    return this.http.get<{ sites: string[] }>(`${this.base}/sites`);
  }
}
