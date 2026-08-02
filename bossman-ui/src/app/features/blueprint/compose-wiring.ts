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
import { BlueprintService, envPrefix, paletteFor } from './compose-model';
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

export interface Provide { capability: string; backend?: string }
export interface Require { capability: string; backends?: string[] }

/** Structured provides — role-grain from `caps` when a contract is loaded, else archetype tokens
 *  (capability only, no backend). */
function providedCaps(s: BlueprintService): Provide[] {
  if (s.caps?.provides?.length) return s.caps.provides.map((p) => ({ capability: p.capability, backend: p.backend }));
  return (paletteFor(s.icon)?.provides ?? []).map((c) => ({ capability: c }));
}
function requiredCaps(s: BlueprintService): Require[] {
  if (s.caps?.requires?.length) return s.caps.requires.map((r) => ({ capability: r.capability, backends: r.backends }));
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

/** `from` depends on `to`; wire the variables the consumer needs to reach it. */
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

  const p = envPrefix(to);
  const port = servicePort(dst);
  const next = services.map((s) => {
    if (s.name !== from) return s;
    const env = { ...s.environment, [`${p}_HOST`]: to };
    const bindings = { ...s.bindings, [`${p}_HOST`]: to };
    if (port) { env[`${p}_PORT`] = String(port); bindings[`${p}_PORT`] = to; }
    return { ...s, dependsOn: [...s.dependsOn, to], environment: env, bindings };
  });
  return { services: next, error: null };
}

/** Remove exactly the keys the `from → to` edge contributed, plus the edge. */
export function unwireOne(s: BlueprintService, to: string): BlueprintService {
  const env = { ...s.environment };
  const bindings = { ...s.bindings };
  for (const [k, src] of Object.entries(s.bindings)) {
    if (src === to) { delete env[k]; delete bindings[k]; }
  }
  return { ...s, dependsOn: s.dependsOn.filter((d) => d !== to), environment: env, bindings };
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
