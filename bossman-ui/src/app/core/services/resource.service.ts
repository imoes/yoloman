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
export type ResourceKind = 'config' | 'docker' | 'helm' | 'k8s' | 'role' | 'package' | 'service' | 'tunable';

/** Identifies one resource instance on one host. */
export interface ResourceRef {
  agentId: string;
  kind: ResourceKind;
  /** Container/release/role name, or the file path for `config`. */
  name: string;
  /** Helm + k8s: the release's / object's namespace. */
  namespace?: string;
  /** k8s only: the Kubernetes cluster id (`?cluster=`); the agent is its access host. */
  cluster?: string;
  /** k8s only: the object's apiVersion (`?api_version=`), e.g. apps/v1. */
  apiVersion?: string;
  /** k8s only: the object's kind (`?object_kind=`), e.g. Deployment. `kind` is the RESOURCE kind. */
  objectKind?: string;
}

/** ResourceRef field → the query parameter the server declares for it (GET /resource-kinds). One table,
 *  so a declared parameter can never be forgotten by one URL builder and remembered by another. */
const QUERY_FIELDS: Record<string, keyof ResourceRef> = {
  namespace: 'namespace', cluster: 'cluster', api_version: 'apiVersion', object_kind: 'objectKind',
};

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
  /** `role` + `k8s`: the state after applying ('active' | 'pending_approval' | 'applied' | …). */
  status?: string;
  /** `k8s`: false when the apply was filed as a ChangeProposal instead of applied. */
  applied?: boolean;
  awaiting_approval?: boolean;
  proposal_id?: string;
  warnings?: string | null;
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

/** `k8s` DELETE …/object — what goes, what stays, and whether it was done. */
export interface K8sDeleteResult {
  ok: boolean;
  preview: boolean;
  error?: string;
  deleted?: boolean;
  generation?: number;
  /** Filed as a change proposal (YOLO mode off): nothing is deleted until it is approved. */
  awaiting_approval?: boolean;
  proposal_id?: string;
  dependents: { kind: string; name: string; why: string }[];
  kept: { kind: string; name: string; why: string }[];
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
  k8s: { addressed_by: 'name', has_schema: true, query_params: ['cluster', 'namespace', 'api_version', 'object_kind'] },
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

  /** Identity that does not fit in the path: the instance itself when it is a path, and every query
   *  parameter the server DECLARES for the kind (helm's namespace; k8s's cluster, namespace, api_version,
   *  object_kind) — read from the ref through one table, never special-cased per kind. */
  private ident(ref: ResourceRef): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    if (this.byPath(ref.kind)) out['path'] = ref.name;
    for (const q of this.kindCaps(ref.kind).query_params) {
      const field = QUERY_FIELDS[q];
      const v = field ? ref[field] : undefined;
      if (v) out[q] = v;
    }
    return out;
  }

  private query(ref: ResourceRef): Record<string, string> {
    const out: Record<string, string> = {};
    for (const [k, v] of Object.entries(this.ident(ref))) out[k] = String(v);
    return out;
  }

  /** `schema()` → the typed fields, rendered by app-param-form. `config` derives its fields from the
   *  codec's directive catalog instead of a static schema, so it has no schema endpoint. */
  schema(ref: ResourceRef): Observable<ParamSchema> {
    // A kind without a schema endpoint must not be asked for one — that request was
    // the concrete damage of guessing (it 404s by design; see /resource-kinds).
    if (!this.kindCaps(ref.kind).has_schema) return of({} as ParamSchema);
    // The API wraps the verb as `{resource_key, type, schema}` (services/resources.read_verb) — unwrap it
    // like observe/generations, or the form renders the envelope's three keys as fields.
    return this.http
      .get<Record<string, unknown>>(this.url(ref, 'schema'), { params: this.query(ref) })
      .pipe(map((b) => {
        const envelope = b && typeof b === 'object' && 'resource_key' in b && 'schema' in b;
        return (envelope ? (b['schema'] as unknown) ?? {} : b) as ParamSchema;
      }));
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
    return this.http.post<ResourceDiff>(this.url(ref, 'plan'), { ...this.ident(ref), ...desired }, { params: this.query(ref) });
  }

  /** `apply(desired)` → make it so. dryRun previews without touching the host. */
  apply(ref: ResourceRef, desired: Record<string, unknown>, dryRun = true, note?: string): Observable<ResourceResult> {
    return this.http.post<ResourceResult>(this.url(ref, 'apply'),
      { ...this.ident(ref), ...desired, dry_run: dryRun, ...(note ? { note } : {}) }, { params: this.query(ref) });
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

  /** `k8s` only: the DELETE extra verb. preview=true lists the dependents that go and the PVCs that stay;
   *  preview=false deletes and records the deletion as a generation (the object shows as vanished). */
  deleteObject(ref: ResourceRef, preview = true, note?: string): Observable<K8sDeleteResult> {
    return this.http.delete<K8sDeleteResult>(
      `${environment.apiUrl}/agents/${ref.agentId}/resources/k8s/${encodeURIComponent(ref.name)}/object`,
      { params: { ...this.query(ref), preview: String(preview), ...(note ? { note } : {}) } });
  }

  rollback(ref: ResourceRef, generation: number): Observable<ResourceResult> {
    return this.http.post<ResourceResult>(this.url(ref, 'rollback'), { ...this.ident(ref), generation }, { params: this.query(ref) });
  }
}
