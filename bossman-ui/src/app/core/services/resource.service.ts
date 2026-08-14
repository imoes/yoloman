import { Injectable, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of } from 'rxjs';
import { map } from 'rxjs/operators';
import { environment } from '../../../environments/environment';
import { ParamSchema } from '../../shared/param-form/param-form.types';

/**
 * One client for the WHOLE Resource protocol (docs/resource-protocol.md), for every kind.
 *
 * The backend already implements the five verbs per kind under
 * `/api/v1/agents/{agentId}/resources/{kind}/…` — schema, observe, plan, apply, generations, rollback.
 * Because the contract is identical across kinds, this service is generic: callers pass a `ResourceRef`
 * and never a kind-specific URL. That is what lets one inspector component render any resource.
 */

/** The kinds the backend implements today. Adding one is a backend file + a descriptor — not a new service. */
export type ResourceKind = 'config' | 'docker' | 'helm' | 'role' | 'package' | 'service';

/** Identifies one resource instance on one host. */
export interface ResourceRef {
  agentId: string;
  kind: ResourceKind;
  /** Container/release/role name, or the file path for `config`. */
  name: string;
  /** Helm only: the release's namespace. */
  namespace?: string;
}

/** `plan()` — the field-wise diff (services/resources/base.diff_specs). */
export interface ResourceDiff {
  action: 'create' | 'update' | 'noop';
  changed: Record<string, [unknown, unknown]>;
  changed_count: number;
  observed?: Record<string, unknown> | null;
  desired?: Record<string, unknown>;
  resource_key?: string;
}

/** `apply()` — dry-run returns just the plan; a real apply records a generation. */
export interface ResourceResult {
  dry_run: boolean;
  ok?: boolean;
  error?: string;
  generation?: number;
  plan?: ResourceDiff;
  /** `role` only: the binding's state after applying ('active' | 'pending' | …). */
  status?: string;
  /** `role` only: how many links `unbind()` removed. */
  unbound?: number;
}

/** Kind-specific extras that some resources add to `apply()`/`unbind()`. They are
 *  DECLARED here rather than left to a second client to discover: `role` reports the
 *  binding's `status` and how many links it `unbound`. */
/** One recorded `apply()` — what `rollback()` restores. */
export interface ResourceGeneration {
  generation: number;
  spec: Record<string, unknown>;
  note?: string | null;
  created_at?: string;
}

/** Aliases kept for the components that used to import from the deleted second
 *  client — ONE type set now describes the protocol's answers. */
export type ResourcePlan = ResourceDiff;
export type ApplyResult = ResourceResult;

/** What one kind can do — served by GET /resource-kinds from the backend registry. */
export interface ResourceKindCaps {
  kind: string;
  label: string;
  /** 'name' → the instance is a path segment; 'path' → it travels in body/query. */
  addressed_by: 'name' | 'path';
  has_schema: boolean;
  verbs: string[];
  query_params: string[];
  extra_verbs: string[];
  needs_identity: boolean;
  needs_address: boolean;
  schema_is_async: boolean;
  observe_includes_schema: boolean;
  generations_scope: string | null;
  notes: string;
}

/** Used only until GET /resource-kinds answers. It deliberately mirrors the server's
 *  registry rather than inventing rules: guessing is exactly what produced a request
 *  for /resources/config/schema, an endpoint that never existed. */
const FALLBACK_CAPS: Record<string, Pick<ResourceKindCaps, 'addressed_by' | 'has_schema' | 'query_params'>> = {
  config: { addressed_by: 'path', has_schema: false, query_params: [] },
  docker: { addressed_by: 'name', has_schema: true, query_params: [] },
  helm: { addressed_by: 'name', has_schema: true, query_params: ['namespace'] },
  role: { addressed_by: 'name', has_schema: true, query_params: [] },
  package: { addressed_by: 'name', has_schema: true, query_params: [] },
  service: { addressed_by: 'name', has_schema: true, query_params: [] },
};

@Injectable({ providedIn: 'root' })
export class ResourceService {
  private http = inject(HttpClient);

  /** The server's registry, loaded once. Until it arrives the fallback above applies,
   *  so the client is never *inventing* a rule — it either knows or mirrors. */
  private caps = signal<Record<string, ResourceKindCaps> | null>(null);

  /** Load the capability table. Safe to call repeatedly; only the first call fetches. */
  loadKinds(): Observable<Record<string, ResourceKindCaps>> {
    const have = this.caps();
    if (have) return of(have);
    return this.http.get<{ kinds: Record<string, ResourceKindCaps> }>(`${environment.apiUrl}/resource-kinds`)
      .pipe(map((r) => { this.caps.set(r.kinds); return r.kinds; }));
  }

  kindCaps(kind: string): Pick<ResourceKindCaps, 'addressed_by' | 'has_schema' | 'query_params'> {
    return this.caps()?.[kind] ?? FALLBACK_CAPS[kind] ?? { addressed_by: 'name', has_schema: true, query_params: [] };
  }

  /** True when the kind is identified by something that cannot sit in a URL segment. */
  private byPath(kind: string): boolean {
    return this.kindCaps(kind).addressed_by === 'path';
  }

  /** The verb URL, derived from the kind's declared addressing — a kind identified by
   *  a path (config) has no `{name}` segment, because a filesystem path cannot ride in
   *  a URL segment unescaped. The rule comes from the server, not from this file. */
  private url(ref: ResourceRef, verb: string): string {
    const base = `${environment.apiUrl}/agents/${ref.agentId}/resources/${ref.kind}`;
    return this.byPath(ref.kind) ? `${base}/${verb}` : `${base}/${encodeURIComponent(ref.name)}/${verb}`;
  }

  /** Identity that does not fit in the path: the instance itself when it is a path, and
   *  any declared query parameter (helm's namespace). */
  private ident(ref: ResourceRef): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    if (this.byPath(ref.kind)) out['path'] = ref.name;
    if (this.kindCaps(ref.kind).query_params.includes('namespace') && ref.namespace) {
      out['namespace'] = ref.namespace;
    }
    return out;
  }

  private query(ref: ResourceRef): Record<string, string> {
    const out: Record<string, string> = {};
    if (this.byPath(ref.kind)) out['path'] = ref.name;
    if (this.kindCaps(ref.kind).query_params.includes('namespace') && ref.namespace) {
      out['namespace'] = ref.namespace;
    }
    return out;
  }

  /** `schema()` → the typed fields, rendered by app-param-form. `config` derives its fields from the
   *  codec's directive catalog instead of a static schema, so it has no schema endpoint. */
  schema(ref: ResourceRef): Observable<ParamSchema> {
    // A kind without a schema endpoint must not be asked for one — that request was
    // the concrete damage of guessing (it 404s by design; see /resource-kinds).
    if (!this.kindCaps(ref.kind).has_schema) return of({} as ParamSchema);
    return this.http.get<ParamSchema>(this.url(ref, 'schema'), { params: this.query(ref) });
  }

  /**
   * `observe()` → what IS on the host right now (null when the resource does not exist yet).
   *
   * The API wraps the verb's value as `{resource_key, observed}` (and `{resource_key, generations}`),
   * while plan/apply return their result unwrapped. Unwrap here so consumers see the VALUE the protocol
   * defines and never the transport envelope.
   */
  observe(ref: ResourceRef): Observable<Record<string, unknown> | null> {
    return this.http
      .get<{ resource_key?: string; observed?: Record<string, unknown> | null }>(
        this.url(ref, 'observe'), { params: this.query(ref) })
      .pipe(map((b) => (b && 'observed' in b ? b.observed ?? null : (b as Record<string, unknown> | null))));
  }

  /** `plan(desired)` → what WOULD change. */
  plan(ref: ResourceRef, desired: Record<string, unknown>): Observable<ResourceDiff> {
    return this.http.post<ResourceDiff>(this.url(ref, 'plan'), { ...this.ident(ref), ...desired });
  }

  /** `apply(desired)` → make it so. dryRun previews without touching the host. */
  apply(ref: ResourceRef, desired: Record<string, unknown>, dryRun = true, note?: string): Observable<ResourceResult> {
    return this.http.post<ResourceResult>(this.url(ref, 'apply'),
      { ...this.ident(ref), ...desired, dry_run: dryRun, ...(note ? { note } : {}) });
  }

  /** The recorded applies, newest first (unwrapped from `{resource_key, generations}`). */
  generations(ref: ResourceRef): Observable<ResourceGeneration[]> {
    return this.http
      .get<{ generations?: ResourceGeneration[] } | ResourceGeneration[]>(
        this.url(ref, 'generations'), { params: this.query(ref) })
      .pipe(map((b) => (Array.isArray(b) ? b : b?.generations ?? [])));
  }

  /** `rollback(generation)` → restore a previous spec. */
  /** `role` only: drop the role/template binding. The one non-verb sub-resource in
   *  the protocol, so it is declared here rather than hidden in a second client. */
  unbind(ref: ResourceRef): Observable<ResourceResult> {
    return this.http.delete<ResourceResult>(
      `${environment.apiUrl}/agents/${ref.agentId}/resources/role/${encodeURIComponent(ref.name)}/binding`);
  }

  rollback(ref: ResourceRef, generation: number): Observable<ResourceResult> {
    return this.http.post<ResourceResult>(this.url(ref, 'rollback'), { ...this.ident(ref), generation });
  }
}
