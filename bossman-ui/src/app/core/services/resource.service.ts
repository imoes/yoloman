import { Injectable, inject } from '@angular/core';
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

@Injectable({ providedIn: 'root' })
export class ResourceService {
  private http = inject(HttpClient);

  /**
   * The verb URL. `config` is the one kind whose instance is addressed by a BODY field (its path) rather
   * than a path segment, because a filesystem path cannot ride in a URL segment unescaped — so it has no
   * `{name}` in the route. Everything else is `/resources/{kind}/{name}/{verb}`.
   */
  private url(ref: ResourceRef, verb: string): string {
    const base = `${environment.apiUrl}/agents/${ref.agentId}/resources/${ref.kind}`;
    return ref.kind === 'config' ? `${base}/${verb}` : `${base}/${encodeURIComponent(ref.name)}/${verb}`;
  }

  /** Fields every kind's body needs to identify the instance (config: path; helm: namespace). */
  private ident(ref: ResourceRef): Record<string, unknown> {
    if (ref.kind === 'config') return { path: ref.name };
    if (ref.kind === 'helm' && ref.namespace) return { namespace: ref.namespace };
    return {};
  }

  private query(ref: ResourceRef): Record<string, string> {
    if (ref.kind === 'config') return { path: ref.name };
    if (ref.kind === 'helm' && ref.namespace) return { namespace: ref.namespace };
    return {};
  }

  /** `schema()` → the typed fields, rendered by app-param-form. `config` derives its fields from the
   *  codec's directive catalog instead of a static schema, so it has no schema endpoint. */
  schema(ref: ResourceRef): Observable<ParamSchema> {
    if (ref.kind === 'config') return of({} as ParamSchema);
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
