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
  Blueprint, BlueprintService, PaletteEntry, sanitizeServiceName,
} from './compose-model';
import { fromComposeText, toComposeJson, toComposeYaml } from './compose-io';
import { openRequirements, openRequirementCaps, removeService, renameService, unwireOne, wireEdge, Require } from './compose-wiring';

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
      environment: {}, values: {}, ports: [], dependsOn: [], bindings: {}, x, y,
    };
    this.patch((list) => [...list, svc]);
    this.selected.set(name);
    return name;
  }

  remove(name: string): void {
    this.patch((list) => removeService(list, name));
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
    const res = renameService(this.bp().services, oldName, next);
    if (res.error) { this.error.set(res.error); return; }
    this.error.set('');
    this.patch(() => res.services);
    if (this.selected() === oldName) this.selected.set(next);
  }

  /**
   * Set the values a param-form produced — ALWAYS the config template's values,
   * never `environment`.
   *
   * The tier does not decide this, which was the bug the stress test exposed: a
   * role's schema comes from configs/config_templates/<name>/schema.json and always
   * describes a config FILE, so its fields are DIRECTIVES (`server.port`,
   * `devices.sysfs_scan`, `feeds.items.url`) whatever tier renders it. 2209 of 29972
   * catalogue fields are not valid POSIX env names, so routing them into
   * `environment:` produced compose files no runtime could apply — for containers
   * just as much as for native services.
   *
   * `environment` therefore holds only what really is an environment variable: the
   * wiring variables an edge contributes, and whatever the author types for an image.
   */
  setValues(name: string, values: Record<string, unknown>): void {
    this.patch((list) => list.map((s) => {
      if (s.name !== name) return s;
      const clean: Record<string, string> = {};
      for (const [k, v] of Object.entries(values)) {
        if (v === undefined || v === null || v === '') continue;
        clean[k] = typeof v === 'object' ? JSON.stringify(v) : String(v);
      }
      return { ...s, values: clean };
    }));
  }

  /** The param-form always edits the template values. */
  formValuesOf(s: BlueprintService): Record<string, string> {
    return s.values ?? {};
  }

  // ---- edges = variable wiring -------------------------------------------

  /**
   * Draw `from → to` (i.e. `from` depends_on `to`) and wire the variables the
   * consumer needs to reach the provider. The keys follow plain Compose practice:
   * a service named `db` is addressed as host `db`, so its peer gets `DB_HOST`
   * (and `DB_PORT` when a port is known).
   */
  connect(from: string, to: string): void {
    const res = wireEdge(this.bp().services, from, to);
    if (res.error) { this.error.set(res.error); return; }
    this.error.set('');
    this.patch(() => res.services);
  }

  /** Remove exactly the keys this edge contributed (never a hand-typed value). */
  private unwire(s: BlueprintService, to: string): BlueprintService {
    return unwireOne(s, to);
  }

  disconnect(from: string, to: string): void {
    this.patch((list) => list.map((s) => (s.name === from ? this.unwire(s, to) : s)));
  }

  /** The capabilities `name` still needs — its role's `requires` not yet met by an existing edge.
   *  Drives the "offene Anforderungen" hint so a placed role shows what it must still be connected to. */
  openRequirements(name: string): string[] {
    const s = this.bp().services.find((x) => x.name === name);
    return s ? openRequirements(s, this.bp().services) : [];
  }

  /** The structured open requirements (capability + accepted backends) — drives the backend provider
   *  suggestion lookup, which needs the raw tokens the display strings hide. */
  openRequirementCaps(name: string): Require[] {
    const s = this.bp().services.find((x) => x.name === name);
    return s ? openRequirementCaps(s, this.bp().services) : [];
  }

  /** Every variable an edge contributed — what the edge inspector edits. */
  bindingsOf(from: string, to: string): { key: string; value: string }[] {
    const s = this.bp().services.find((x) => x.name === from);
    if (!s) return [];
    return Object.entries(s.bindings)
      .filter(([, src]) => src === to)
      .map(([key]) => ({ key, value: s.environment[key] ?? '' }))
      .sort((a, b) => a.key.localeCompare(b.key));
  }

  /** Rename a wired variable — the consumer may expect PGHOST rather than DB_HOST.
   * Keeps the value and the provenance, so the edge still owns the key. */
  renameBinding(service: string, oldKey: string, rawNew: string): void {
    const next = rawNew.trim().replace(/[^A-Za-z0-9_]/g, '_');
    if (!next || next === oldKey) return;
    this.patch((list) => list.map((s) => {
      if (s.name !== service || !(oldKey in s.bindings)) return s;
      if (next in s.environment) { this.error.set(`${next} ist in ${service} schon gesetzt.`); return s; }
      const env = { ...s.environment }; const bind = { ...s.bindings };
      env[next] = env[oldKey]; bind[next] = bind[oldKey];
      delete env[oldKey]; delete bind[oldKey];
      return { ...s, environment: env, bindings: bind };
    }));
  }

  /** Override a wired value by hand (e.g. a read-replica address instead of the
   * service name). Provenance is kept so the inspector can still say where it came
   * from — and `disconnect` still knows the key belongs to this edge. */
  setBindingValue(service: string, key: string, value: string): void {
    this.patch((list) => list.map((s) =>
      s.name === service && key in s.bindings
        ? { ...s, environment: { ...s.environment, [key]: value } }
        : s));
  }

  /** Drop one wired variable without removing the edge. */
  removeBinding(service: string, key: string): void {
    this.patch((list) => list.map((s) => {
      if (s.name !== service || !(key in s.bindings)) return s;
      const env = { ...s.environment }; const bind = { ...s.bindings };
      delete env[key]; delete bind[key];
      return { ...s, environment: env, bindings: bind };
    }));
  }

  /** Add another variable to an existing edge — defaults to the peer's name, which
   * is how Compose addresses it. */
  addBinding(service: string, target: string, rawKey: string): void {
    const key = rawKey.trim().replace(/[^A-Za-z0-9_]/g, '_').toUpperCase();
    if (!key) return;
    this.patch((list) => list.map((s) => {
      if (s.name !== service) return s;
      if (key in s.environment) { this.error.set(`${key} ist in ${service} schon gesetzt.`); return s; }
      return { ...s, environment: { ...s.environment, [key]: target },
               bindings: { ...s.bindings, [key]: target } };
    }));
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
          ...s, environment: s.environment ?? {}, values: s.values ?? {}, ports: s.ports ?? [],
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
