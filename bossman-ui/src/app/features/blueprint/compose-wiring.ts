/**
 * Pure wiring logic — extracted from BlueprintStore so it can be exercised without
 * Angular (see scripts/stress-blueprint.mjs, which drives these very functions over
 * every config template in the catalogue). The store keeps the signals; the rules
 * live here.
 *
 * The rule that matters: an edge does not just record `depends_on`, it WIRES
 * VARIABLES. `web → db` writes `DB_HOST=db` (+ `DB_PORT`) into web's environment,
 * following plain Compose practice that a service name IS its address, and records
 * the provenance so unwiring removes exactly those keys and never a hand-typed one.
 */
import { BlueprintService, FieldSource, envPrefix, paletteFor } from './compose-model';
import { servicePort } from './compose-io';

export interface WireResult {
  services: BlueprintService[];
  /** null on success, else why the edge was refused */
  error: string | null;
}

/** Wire-compatible backend substitutes — mirrors configs/capability_vocabulary.json `backend_aliases`
 *  so the editor's LOCAL plausibility matches the backend matcher: a consumer accepting `mysql` also
 *  accepts `mariadb`. (Inventory suggestions come from the backend, which expands these server-side;
 *  this small copy is only for node↔node checks that must work offline.) */
const BACKEND_ALIASES: Record<string, string[]> = {
  mysql: ['mariadb'], mariadb: ['mysql'], redis: ['valkey', 'keydb'],
};
function expandBackends(backends: string[]): Set<string> {
  const out = new Set<string>();
  for (const b of backends) { if (!b) continue; out.add(b); for (const a of BACKEND_ALIASES[b] ?? []) out.add(a); }
  return out;
}

export interface Provide { capability: string; backend?: string; default_port?: number | null;
                           field_sources?: Record<string, FieldSource> }
export interface Require { capability: string; backends?: string[];
                          fields?: Record<string, string>; field_targets?: Record<string, string> }

/** Structured provides — role-grain from `caps` when a contract is loaded, else archetype tokens
 *  (capability only, no backend). Carries field_sources so the connector can resolve every field. */
function providedCaps(s: BlueprintService): Provide[] {
  if (s.caps?.provides?.length) return s.caps.provides.map((p) => ({
    capability: p.capability, backend: p.backend, default_port: p.default_port, field_sources: p.field_sources }));
  return (paletteFor(s.icon)?.provides ?? []).map((c) => ({ capability: c }));
}
function requiredCaps(s: BlueprintService): Require[] {
  if (s.caps?.requires?.length) return s.caps.requires.map((r) => ({
    capability: r.capability, backends: r.backends, fields: r.fields, field_targets: r.field_targets }));
  return (paletteFor(s.icon)?.requires ?? []).map((c) => ({ capability: c }));
}

/** True when a provide can satisfy a require: same capability, and — when both name backends — the
 *  provider's backend is one the consumer accepts (alias-aware). Unknown backend on either side is
 *  permissive (archetype-grain fallback stays as loose as before). */
function satisfies(req: Require, prov: Provide): boolean {
  if (req.capability !== prov.capability) return false;
  if (!req.backends?.length || !prov.backend) return true;
  return expandBackends(req.backends).has(prov.backend);
}

/** Display tokens (backend-qualified where known) — used in the inspector and refusal messages. */
export function providesOf(s: BlueprintService): string[] {
  return providedCaps(s).map((p) => (p.backend ? `${p.capability}:${p.backend}` : p.capability));
}
export function requiresOf(s: BlueprintService): string[] {
  return requiredCaps(s).map((r) => (r.backends?.length ? `${r.capability} (${r.backends.join('|')})` : r.capability));
}

/** Which requirement of `from` is satisfied by a capability of `to` — the reason an edge is plausible
 *  (returned as a display token), or null when none is (so the caller can explain the refusal). Now
 *  backend-aware: a Postgres does NOT satisfy a consumer that requires database:[mysql,mariadb]. */
export function capabilityMatch(from: BlueprintService, to: BlueprintService): string | null {
  const offered = providedCaps(to);
  for (const req of requiredCaps(from)) {
    if (offered.some((p) => satisfies(req, p))) {
      return req.backends?.length ? `${req.capability} (${req.backends.join('|')})` : req.capability;
    }
  }
  return null;
}

/** Structured open requirements (capability + accepted backends) — an unmet require is one no current
 *  dependency satisfies (backend-aware). Drives both the display tokens and the backend provider lookup. */
export function openRequirementCaps(service: BlueprintService, services: BlueprintService[]): Require[] {
  const deps = service.dependsOn
    .map((n) => services.find((s) => s.name === n))
    .filter((d): d is BlueprintService => !!d);
  return requiredCaps(service).filter(
    (req) => !deps.some((dep) => providedCaps(dep).some((p) => satisfies(req, p))));
}

/** A requirement is OPEN when no service this one already depends on satisfies it (backend-aware). */
export function openRequirements(service: BlueprintService, services: BlueprintService[]): string[] {
  return openRequirementCaps(service, services)
    .map((r) => (r.backends?.length ? `${r.capability} (${r.backends.join('|')})` : r.capability));
}

/** The consumer requirement + the provider capability that satisfies it (the pair
 *  an edge wires), or null. Lets the connector resolve fields, not just check. */
function matchPair(from: BlueprintService, to: BlueprintService): { req: Require; prov: Provide } | null {
  const offered = providedCaps(to);
  for (const req of requiredCaps(from)) {
    const prov = offered.find((p) => satisfies(req, p));
    if (prov) return { req, prov };
  }
  return null;
}

const MASK = '••••••••';

/** Resolve one connection field's value from the provider `to` — mirrors the
 *  backend `_service_source_value`. Returns null when the provider offers no source
 *  for it (a missing credential the plausibility panel then flags). */
function fieldValue(field: string, spec: FieldSource | undefined, to: BlueprintService, prov: Provide): { value: string; secret: boolean } | null {
  const secret = !!spec?.secret;
  const addr = to.address || to.name;                 // compose name is the DNS address
  const port = prov.default_port ?? servicePort(to);
  const nonEmpty = (v: unknown): v is string => v !== undefined && v !== null && String(v) !== '';
  if (!spec) {                                        // no explicit source → universal defaults
    if (field === 'host') return { value: addr, secret: false };
    if (field === 'port' && port != null) return { value: String(port), secret: false };
    return null;
  }
  switch (spec.from) {
    case 'address': return { value: addr, secret };
    case 'port': return port != null ? { value: String(port), secret } : null;
    case 'const': return nonEmpty(spec.value) ? { value: String(spec.value), secret } : null;
    case 'env': { const v = to.environment?.[spec.key ?? '']; return nonEmpty(v) ? { value: v, secret } : null; }
    case 'value': { const v = to.values?.[spec.key ?? '']; return nonEmpty(v) ? { value: v, secret } : null; }
  }
  return null;
}

/** The full set of variables an edge `from → to` wires: every connection field the
 *  consumer targets, resolved from the provider's sources. Falls back to HOST/PORT
 *  when no contract (archetype-grain node). Secrets are masked in the canvas — the
 *  real value is re-derived and vault-encoded at bind. */
export function wiredFields(from: BlueprintService, to: BlueprintService): { key: string; value: string }[] {
  const pair = matchPair(from, to);
  const p = envPrefix(to.name);
  if (!pair) {  // unconstrained/archetype edge — keep the classic host/port wiring
    const out = [{ key: `${p}_HOST`, value: to.name }];
    const port = servicePort(to);
    if (port) out.push({ key: `${p}_PORT`, value: String(port) });
    return out;
  }
  const targets = pair.req.field_targets || pair.req.fields
    || { host: `${p}_HOST`, port: `${p}_PORT` };
  const sources = pair.prov.field_sources || {};
  const out: { key: string; value: string }[] = [];
  for (const [field, key] of Object.entries(targets)) {
    if (!key) continue;
    const resolved = fieldValue(field, sources[field], to, pair.prov);
    if (resolved) out.push({ key, value: resolved.secret ? MASK : resolved.value });
  }
  return out;
}

/** `from` depends on `to`; wire EVERY connection field the consumer needs to reach
 *  it (host/port/name/user/password), into `environment` (docker) or `values`
 *  (native config directives). */
export function wireEdge(services: BlueprintService[], from: string, to: string): WireResult {
  if (from === to) return { services, error: 'A service cannot depend on itself.' };
  const src = services.find((s) => s.name === from);
  const dst = services.find((s) => s.name === to);
  if (!src || !dst) return { services, error: `Unknown service (${from} → ${to}).` };
  if (src.dependsOn.includes(to)) return { services, error: `${from} already depends on ${to}.` };

  // Plausibility: an edge is only allowed when the target provides a capability the source requires.
  // A source that declares NO requirements is unconstrained (a generic Server/Container can depend on
  // anything) — the check only bites once a role with real requirements is chosen, which is the point.
  if (requiresOf(src).length > 0 && capabilityMatch(src, dst) === null) {
    const need = requiresOf(src).join(', ');
    const got = providesOf(dst).join(', ') || '—';
    return {
      services,
      error: `${from} needs [${need}], but ${to} provides [${got}]. Connect ${from} to a matching service.`,
    };
  }

  const fields = wiredFields(src, dst);
  const toValues = src.kind === 'native';   // native consumers take config directives, not env
  const next = services.map((s) => {
    if (s.name !== from) return s;
    const env = { ...s.environment };
    const values = { ...(s.values ?? {}) };
    const bindings = { ...s.bindings };
    const target = toValues ? values : env;
    for (const { key, value } of fields) { target[key] = value; bindings[key] = to; }
    return { ...s, dependsOn: [...s.dependsOn, to], environment: env, values, bindings };
  });
  return { services: next, error: null };
}

/** Remove exactly the keys the `from → to` edge contributed (from env AND values),
 *  plus the edge. */
export function unwireOne(s: BlueprintService, to: string): BlueprintService {
  const env = { ...s.environment };
  const values = { ...(s.values ?? {}) };
  const bindings = { ...s.bindings };
  for (const [k, src] of Object.entries(s.bindings)) {
    if (src === to) { delete env[k]; delete values[k]; delete bindings[k]; }
  }
  return { ...s, dependsOn: s.dependsOn.filter((d) => d !== to), environment: env, values, bindings };
}

export function unwireEdge(services: BlueprintService[], from: string, to: string): BlueprintService[] {
  return services.map((s) => (s.name === from ? unwireOne(s, to) : s));
}

/** Deleting a service must also drop every edge into it and the variables those
 * edges wired — otherwise a blueprint keeps pointing at something that is gone. */
export function removeService(services: BlueprintService[], name: string): BlueprintService[] {
  return services
    .filter((s) => s.name !== name)
    .map((s) => (s.dependsOn.includes(name) ? unwireOne(s, name) : s));
}

/**
 * Rename a service and keep every reference intact. A compose service name IS its
 * address, so a rename rewrites the edges, the wired values that point at it, and
 * the provenance map of everyone depending on it.
 */
export function renameService(
  services: BlueprintService[], oldName: string, newName: string,
): WireResult {
  if (!newName || newName === oldName) return { services, error: null };
  if (services.some((s) => s.name === newName)) {
    return { services, error: `Der Name "${newName}" ist schon belegt.` };
  }
  const next = services.map((s) => {
    const svc: BlueprintService = s.name === oldName ? { ...s, name: newName } : { ...s };
    svc.dependsOn = svc.dependsOn.map((d) => (d === oldName ? newName : d));
    const env: Record<string, string> = {};
    for (const [k, v] of Object.entries(svc.environment)) env[k] = v === oldName ? newName : v;
    svc.environment = env;
    const vals: Record<string, string> = {};
    for (const [k, v] of Object.entries(svc.values ?? {})) vals[k] = v === oldName ? newName : v;
    svc.values = vals;
    const bind: Record<string, string> = {};
    for (const [k, v] of Object.entries(svc.bindings)) bind[k] = v === oldName ? newName : v;
    svc.bindings = bind;
    return svc;
  });
  return { services: next, error: null };
}
