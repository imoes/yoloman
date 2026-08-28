import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { Graph, GraphInput } from '../models/graph.model';

/** REST client for saved charts (/api/v1/graphs). The rendered data comes from the
 * dashboard widget that references the graph, not from here — one series computation lives
 * in services/graph_data.py and both routes use it. */
@Injectable({ providedIn: 'root' })
export class GraphService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/graphs`;

  list() {
    return this.http.get<Graph[]>(this.base);
  }

  get(id: string) {
    return this.http.get<Graph>(`${this.base}/${id}`);
  }

  create(body: GraphInput) {
    return this.http.post<Graph>(this.base, body);
  }

  update(id: string, body: GraphInput) {
    return this.http.put<Graph>(`${this.base}/${id}`, body);
  }

  delete(id: string) {
    return this.http.delete<void>(`${this.base}/${id}`);
  }
}
