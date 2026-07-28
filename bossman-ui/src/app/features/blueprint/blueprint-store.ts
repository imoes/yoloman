/**
 * Blueprint state — signals + localStorage. No backend: the prototype writes
 * nothing to the fleet (there is no mutating Systems API to write to yet, and the
 * point of this branch is to judge the editor, not to ship a rollout).
 *
 * The interesting logic is `connect()`: drawing an edge does not just record
 * `depends_on`, it WIRES VARIABLES. Connecting `web → db` writes `DB_HOST=db` (and
 * `DB_PORT`) into web's environment and remembers the provenance in `bindings`, so
 * the inspector can say where a value came from and `disconnect()` can take exactly
 * those keys away again. That is what makes the graph worth drawing — see the plan.
 */
import { Injectable, computed, signal } from '@angular/core';
import {
  Blueprint, BlueprintService, PaletteEntry, envPrefix, sanitizeServiceName,
} from './compose-model';
import { fromComposeText, servicePort, toComposeJson, toComposeYaml } from './compose-io';

const STORAGE_KEY = 'bm_blueprint_draft';

function emptyBlueprint(): Blueprint {
  return { name: 'mein-stack', services: [] };
}

@Injectable({ providedIn: 'root' })
export class BlueprintStore {
  private bp = signal<Blueprint>(emptyBlueprint());
  readonly blueprint = this.bp.asReadonly();
  readonly selected = signal<string | null>(null);
  readonly error = signal('');

  readonly services = computed(() => this.bp().services);
  readonly selectedService = computed(() =>
    this.bp().services.find((s) => s.name === this.selected()) ?? null);
  readonly composeYaml = computed(() => toComposeYaml(this.bp()));
  readonly composeJson = computed(() => toComposeJson(this.bp()));

  constructor() { this.load(); }

  // ---- mutation ----------------------------------------------------------

  private patch(fn: (services: BlueprintService[]) => BlueprintService[]): void {
    this.bp.update((b) => ({ ...b, services: fn([...b.services]) }));
    this.persist();
  }

  setName(name: string): void {
    this.bp.update((b) => ({ ...b, name: sanitizeServiceName(name) || 'blueprint' }));
    this.persist();
  }

  /** Unique compose service name from a palette prefix: db, db2, db3… */
  private freshName(prefix: string): string {
    const taken = new Set(this.bp().services.map((s) => s.name));
    if (!taken.has(prefix)) return prefix;
    for (let i = 2; i < 999; i++) if (!taken.has(`${prefix}${i}`)) return `${prefix}${i}`;
    return `${prefix}${Date.now()}`;
  }

  add(entry: PaletteEntry, x: number, y: number): string {
    const name = this.freshName(entry.prefix);
    const svc: BlueprintService = {
      name, kind: entry.kind, icon: entry.icon,
      environment: {}, ports: [], dependsOn: [], bindings: {}, x, y,
    };
    this.patch((list) => [...list, svc]);
    this.selected.set(name);
    return name;
  }

  remove(name: string): void {
    this.patch((list) => list
      .filter((s) => s.name !== name)
      // drop dangling edges AND the variables they had wired
      .map((s) => s.dependsOn.includes(name) ? this.unwire(s, name) : s));
    if (this.selected() === name) this.selected.set(null);
  }

  move(name: string, x: number, y: number): void {
    this.patch((list) => list.map((s) => s.name === name ? { ...s, x, y } : s));
  }

  update(name: string, changes: Partial<BlueprintService>): void {
    this.patch((list) => list.map((s) => s.name === name ? { ...s, ...changes } : s));
  }

  /** Rename a service and keep every reference intact (edges, wired values and
   * their provenance) — a compose service name IS its address, so a rename
   * changes the wiring of everyone pointing at it. */
  rename(oldName: string, rawNew: string): void {
    const next = sanitizeServiceName(rawNew);
    if (!next || next === oldName) return;
    if (this.bp().services.some((s) => s.name === next)) {
      this.error.set(`Der Name "${next}" ist schon belegt.`);
      return;
    }
    this.error.set('');
    this.patch((list) => list.map((s) => {
      const svc: BlueprintService = s.name === oldName ? { ...s, name: next } : { ...s };
      svc.dependsOn = svc.dependsOn.map((d) => (d === oldName ? next : d));
      const env: Record<string, string> = {};
      for (const [k, v] of Object.entries(svc.environment)) env[k] = v === oldName ? next : v;
      svc.environment = env;
      const bind: Record<string, string> = {};
      for (const [k, v] of Object.entries(svc.bindings)) bind[k] = v === oldName ? next : v;
      svc.bindings = bind;
      return svc;
    }));
    if (this.selected() === oldName) this.selected.set(next);
  }

  /** Set the values a param-form produced. Auto-wired keys (bindings) are kept —
   * a form edit must not silently drop the values an edge contributed. */
  setValues(name: string, values: Record<string, unknown>): void {
    this.patch((list) => list.map((s) => {
      if (s.name !== name) return s;
      const env: Record<string, string> = {};
      for (const [k, v] of Object.entries(values)) {
        if (v === undefined || v === null || v === '') continue;
        env[k] = typeof v === 'object' ? JSON.stringify(v) : String(v);
      }
      for (const k of Object.keys(s.bindings)) if (s.environment[k]) env[k] = s.environment[k];
      return { ...s, environment: env };
    }));
  }

  // ---- edges = variable wiring -------------------------------------------

  /**
   * Draw `from → to` (i.e. `from` depends_on `to`) and wire the variables the
   * consumer needs to reach the provider. The keys follow plain Compose practice:
   * a service named `db` is addressed as host `db`, so its peer gets `DB_HOST`
   * (and `DB_PORT` when a port is known).
   */
  connect(from: string, to: string): void {
    if (from === to) { this.error.set('Ein Dienst kann nicht von sich selbst abhängen.'); return; }
    const svcs = this.bp().services;
    const src = svcs.find((s) => s.name === from);
    const dst = svcs.find((s) => s.name === to);
    if (!src || !dst) return;
    if (src.dependsOn.includes(to)) { this.error.set(`${from} hängt schon von ${to} ab.`); return; }
    this.error.set('');

    const p = envPrefix(to);
    const port = servicePort(dst);
    this.patch((list) => list.map((s) => {
      if (s.name !== from) return s;
      const env = { ...s.environment, [`${p}_HOST`]: to };
      const bindings = { ...s.bindings, [`${p}_HOST`]: to };
      if (port) { env[`${p}_PORT`] = String(port); bindings[`${p}_PORT`] = to; }
      return { ...s, dependsOn: [...s.dependsOn, to], environment: env, bindings };
    }));
  }

  /** Remove exactly the keys this edge contributed (never a hand-typed value). */
  private unwire(s: BlueprintService, to: string): BlueprintService {
    const env = { ...s.environment };
    const bindings = { ...s.bindings };
    for (const [k, src] of Object.entries(s.bindings)) {
      if (src === to) { delete env[k]; delete bindings[k]; }
    }
    return { ...s, dependsOn: s.dependsOn.filter((d) => d !== to), environment: env, bindings };
  }

  disconnect(from: string, to: string): void {
    this.patch((list) => list.map((s) => (s.name === from ? this.unwire(s, to) : s)));
  }

  // ---- persistence / IO --------------------------------------------------

  private persist(): void {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(this.bp())); } catch { /* quota — draft is best-effort */ }
  }

  private load(): void {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return;
      const parsed = JSON.parse(raw) as Blueprint;
      if (parsed && Array.isArray(parsed.services)) {
        // tolerate drafts written before a field existed
        parsed.services = parsed.services.map((s) => ({
          ...s, environment: s.environment ?? {}, ports: s.ports ?? [],
          dependsOn: s.dependsOn ?? [], bindings: s.bindings ?? {},
        }));
        this.bp.set(parsed);
      }
    } catch { /* corrupt draft: start empty rather than crash the page */ }
  }

  reset(): void {
    this.bp.set(emptyBlueprint());
    this.selected.set(null);
    this.error.set('');
    this.persist();
  }

  /** Import a compose.yaml / .json — the round-trip proof. */
  importCompose(text: string): void {
    try {
      this.bp.set(fromComposeText(text));
      this.selected.set(null);
      this.error.set('');
      this.persist();
    } catch (e) {
      this.error.set(`Import fehlgeschlagen: ${(e as Error).message}`);
    }
  }
}
