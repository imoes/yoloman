import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

/** A docker container's desired/observed spec (the Resource's values). */
export interface DockerSpec {
  name?: string;
  image: string;
  ports: { host: number | string; container: number | string }[];
  env: Record<string, unknown>;
  volumes: string[];
  restart: string;
}

export interface ResourcePlan {
  action: 'create' | 'update' | 'noop';
  changed: Record<string, [unknown, unknown]>;
  changed_count: number;
  observed?: Record<string, unknown> | null;
  desired?: Record<string, unknown>;
  resource_key?: string;
}

export interface ResourceGeneration {
  generation: number;
  spec: Record<string, unknown>;
  note?: string | null;
  applied_by?: string | null;
  applied_at?: string | null;
}

export interface ApplyResult {
  dry_run: boolean;
  ok?: boolean;
  generation?: number;
  error?: string;
  plan?: ResourcePlan;
  // role tier: a binding starts active only under YOLO / waived approval,
  // otherwise pending_approval (the governance gate).
  status?: 'active' | 'pending_approval' | string;
  bound?: boolean;
  awaiting_approval?: boolean;
}

export interface UnbindResult {
  ok: boolean;
  unbound?: number;
  error?: string;
}

/** Resource / Deployable client (docs/resource-protocol.md) — the four verbs
 * across tiers (kind = 'docker' | 'helm'): schema / observe / plan / apply /
 * generations / rollback. One client for every Resource type — the node and the
 * AI drive the same interface. `namespace` applies to the helm tier. */
@Injectable({ providedIn: 'root' })
export class ResourcesService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/agents`;

  /** URL shape per tier: docker/helm are name-in-path; config is path-in-query
   * (a file path can't live in a path segment). */
  private path(id: string, kind: string, name: string) {
    if (kind === 'config') return `${this.base}/${id}/resources/config`;
    return `${this.base}/${id}/resources/${kind}/${encodeURIComponent(name)}`;
  }
  private opts(kind: string, namespace?: string, name?: string): { params: Record<string, string> } {
    if (kind === 'config') return { params: { path: name || '' } };
    if (kind === 'helm' && namespace) return { params: { namespace } };
    return { params: {} };
  }

  /** Typed field schema. The config tier has no /schema route — its schema comes
   * back from observe, so the node falls back to that. */
  schema(id: string, kind: string, name: string, namespace?: string) {
    return this.http.get<{ resource_key: string; type: string; schema: Record<string, unknown> }>(`${this.path(id, kind, name)}/schema`, this.opts(kind, namespace, name));
  }
  observe(id: string, kind: string, name: string, namespace?: string) {
    return this.http.get<{ resource_key: string; observed: Record<string, unknown> | null; schema?: Record<string, unknown> }>(`${this.path(id, kind, name)}/observe`, this.opts(kind, namespace, name));
  }
  plan(id: string, kind: string, name: string, desired: Record<string, unknown>, namespace?: string) {
    return this.http.post<ResourcePlan>(`${this.path(id, kind, name)}/plan`, desired, this.opts(kind, namespace, name));
  }
  apply(id: string, kind: string, name: string, desired: Record<string, unknown>, dry_run: boolean, note?: string, namespace?: string) {
    return this.http.post<ApplyResult>(`${this.path(id, kind, name)}/apply`, { ...desired, dry_run, note }, this.opts(kind, namespace, name));
  }
  generations(id: string, kind: string, name: string, namespace?: string) {
    return this.http.get<{ resource_key: string; scope?: string; generations: ResourceGeneration[] }>(`${this.path(id, kind, name)}/generations`, this.opts(kind, namespace, name));
  }
  rollback(id: string, kind: string, name: string, generation: number, namespace?: string) {
    return this.http.post<ApplyResult>(`${this.path(id, kind, name)}/rollback`, { generation }, this.opts(kind, namespace, name));
  }
  /** role tier only: remove this host's direct binding of the role (counterpart of
   * apply/Bind). DELETE …/role/{name}/binding. */
  unbind(id: string, name: string) {
    return this.http.delete<UnbindResult>(`${this.base}/${id}/resources/role/${encodeURIComponent(name)}/binding`);
  }
}
