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
import { BlueprintService, envPrefix } from './compose-model';
import { servicePort } from './compose-io';

export interface WireResult {
  services: BlueprintService[];
  /** null on success, else why the edge was refused */
  error: string | null;
}

/** `from` depends on `to`; wire the variables the consumer needs to reach it. */
export function wireEdge(services: BlueprintService[], from: string, to: string): WireResult {
  if (from === to) return { services, error: 'Ein Dienst kann nicht von sich selbst abhängen.' };
  const src = services.find((s) => s.name === from);
  const dst = services.find((s) => s.name === to);
  if (!src || !dst) return { services, error: `Unbekannter Dienst (${from} → ${to}).` };
  if (src.dependsOn.includes(to)) return { services, error: `${from} hängt schon von ${to} ab.` };

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
