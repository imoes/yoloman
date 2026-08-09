/**
 * Blueprint ⇄ Docker Compose. The graph IS the document: there is no separate
 * "blueprint format" to keep in sync — `toCompose()` emits a valid Compose
 * document and `fromCompose()` reads one back, so an existing compose.yaml can be
 * opened in the editor and a hand-edit outside the editor is not lost.
 *
 * Everything Compose cannot express (placement, role instead of image, canvas
 * layout, wiring provenance) rides in `x-yolo-*` extension keys, which the
 * compose-spec explicitly reserves for exactly this — so `docker compose config`
 * still accepts the output.
 */
import yaml from 'js-yaml';
import {
  Blueprint, BlueprintService, ServiceKind, paletteFor, sanitizeServiceName,
} from './compose-model';

/** A compose service as it appears in the document (only the keys we touch). */
interface ComposeService {
  image?: string;
  environment?: Record<string, string> | string[];
  ports?: (string | number)[];
  depends_on?: string[] | Record<string, unknown>;
  'x-yolo-kind'?: ServiceKind;
  'x-yolo-host'?: string;
  'x-yolo-address'?: string;
  'x-yolo-role'?: string;
  'x-yolo-template'?: string;
  'x-yolo-icon'?: string;
  'x-yolo-layout'?: { x: number; y: number };
  'x-yolo-bindings'?: Record<string, string>;
  'x-yolo-values'?: Record<string, string>;
  [k: string]: unknown;
}

interface ComposeDoc {
  name?: string;
  services?: Record<string, ComposeService>;
  [k: string]: unknown;
}

/**
 * Blueprint → document object.
 *
 * `meta: true` (the default) emits our FULL document: plain Compose plus the
 * `x-yolo-*` extensions that carry what Compose cannot say (tier, role, placement,
 * canvas layout, wiring provenance). That is the round-trippable source of truth.
 *
 * `meta: false` emits CLEAN Compose — nothing but what Compose itself defines. That
 * is what you hand to `docker compose`, and what a human wants to read; the editor's
 * bookkeeping has no business in it.
 */
export function toComposeDoc(bp: Blueprint, meta = true): ComposeDoc {
  const services: Record<string, ComposeService> = {};
  for (const s of bp.services) {
    const svc: ComposeService = {};
    // Native services have no image — the role + template are the artifact.
    if (s.kind === 'docker' && s.image) svc.image = s.image;
    if (Object.keys(s.environment).length) svc.environment = { ...s.environment };
    if (s.ports.length) svc.ports = [...s.ports];
    if (s.dependsOn.length) svc.depends_on = [...s.dependsOn];
    if (meta) {
      svc['x-yolo-kind'] = s.kind;
      svc['x-yolo-icon'] = s.icon;
      if (s.role) svc['x-yolo-role'] = s.role;
      if (s.host) svc['x-yolo-host'] = s.host;
      if (s.address) svc['x-yolo-address'] = s.address;
      if (s.template) svc['x-yolo-template'] = s.template;
      if (Object.keys(s.bindings).length) svc['x-yolo-bindings'] = { ...s.bindings };
      if (Object.keys(s.values).length) svc['x-yolo-values'] = { ...s.values };
      svc['x-yolo-layout'] = { x: Math.round(s.x), y: Math.round(s.y) };
    }
    services[s.name] = svc;
  }
  return { name: bp.name, services };
}

/** Clean `compose.yaml` — no editor metadata (see toComposeDoc). */
export function toComposeYaml(bp: Blueprint): string {
  return yaml.dump(toComposeDoc(bp, false), { lineWidth: -1, noRefs: true, sortKeys: false });
}

/** The full blueprint document (Compose + x-yolo-* meta) — this is what round-trips. */
export function toComposeJson(bp: Blueprint): string {
  return JSON.stringify(toComposeDoc(bp, true), null, 2);
}

/** `environment` may be a mapping OR a `KEY=value` list — normalize to a mapping. */
function normalizeEnv(env: ComposeService['environment']): Record<string, string> {
  if (!env) return {};
  if (Array.isArray(env)) {
    const out: Record<string, string> = {};
    for (const entry of env) {
      const i = String(entry).indexOf('=');
      if (i > 0) out[String(entry).slice(0, i)] = String(entry).slice(i + 1);
      else out[String(entry)] = '';
    }
    return out;
  }
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) out[k] = v == null ? '' : String(v);
  return out;
}

/** `depends_on` may be a list OR the long form `{svc: {condition: …}}`. */
function normalizeDependsOn(dep: ComposeService['depends_on']): string[] {
  if (!dep) return [];
  return Array.isArray(dep) ? dep.map(String) : Object.keys(dep);
}

/** Guess an icon for a service imported from a plain compose file (no x-yolo-icon):
 * match the image/name against the palette's own prefixes and a few well-known
 * images, so an imported stack doesn't come up as 15 identical boxes. */
function guessIcon(name: string, image: string | undefined, kind: ServiceKind): string {
  const hay = `${name} ${image ?? ''}`.toLowerCase();
  const rules: [RegExp, string][] = [
    [/postgres|mysql|mariadb|mongo|sqlserver|oracle/, 'database'],
    [/redis|memcache/, 'cache'],
    [/rabbit|kafka|nats|activemq/, 'queue'],
    [/nginx|apache|httpd|caddy|traefik|proxy/, 'proxy'],
    [/haproxy|balancer|\blb\b/, 'loadbalancer'],
    [/minio|ceph|nfs|storage/, 'storage'],
    [/firewall|\bfw\b/, 'firewall'],
    [/kube|k8s|helm/, 'k8s'],
  ];
  for (const [re, icon] of rules) if (re.test(hay)) return icon;
  return kind === 'docker' ? 'container' : 'server';
}

/** Compose (YAML or JSON text) → Blueprint. Unknown keys are preserved only where
 * we model them; the importer is deliberately forgiving so a real-world file opens. */
export function fromComposeText(text: string): Blueprint {
  const doc = (yaml.load(text) ?? {}) as ComposeDoc;
  if (!doc || typeof doc !== 'object') throw new Error('Kein Compose-Dokument.');
  const raw = doc.services;
  if (!raw || typeof raw !== 'object') throw new Error("Kein 'services:' im Dokument.");

  const names = Object.keys(raw);
  const services: BlueprintService[] = names.map((name, i) => {
    const svc = raw[name] ?? {};
    const kind: ServiceKind = svc['x-yolo-kind'] ?? (svc.image ? 'docker' : 'native');
    const icon = svc['x-yolo-icon'] ?? guessIcon(name, svc.image, kind);
    const layout = svc['x-yolo-layout'];
    // No stored layout (a foreign compose file): lay out on a grid so nothing
    // stacks at the origin — the user can then "Anordnen" or drag.
    const x = layout?.x ?? 120 + (i % 4) * 200;
    const y = layout?.y ?? 120 + Math.floor(i / 4) * 170;
    return {
      name: sanitizeServiceName(name) || `svc${i + 1}`,
      kind,
      icon,
      role: svc['x-yolo-role'],
      image: svc.image,
      host: svc['x-yolo-host'],
      address: svc['x-yolo-address'],
      template: svc['x-yolo-template'],
      environment: normalizeEnv(svc.environment),
      ports: (svc.ports ?? []).map(String),
      dependsOn: normalizeDependsOn(svc.depends_on).filter((d) => names.includes(d)),
      bindings: svc['x-yolo-bindings'] ?? {},
      values: svc['x-yolo-values'] ?? {},
      x, y,
    };
  });

  return { name: typeof doc.name === 'string' && doc.name ? doc.name : 'blueprint', services };
}

/** Default port for a service, used when auto-wiring `<PREFIX>_PORT`: its own
 * first published port wins, else the palette's default for that icon. */
export function servicePort(s: BlueprintService): number | undefined {
  const first = s.ports[0];
  if (first) {
    // "8080:80" → 80 (the container/service side is what a peer connects to)
    const parts = String(first).split(':');
    const n = Number(parts[parts.length - 1]);
    if (Number.isFinite(n) && n > 0) return n;
  }
  return paletteFor(s.icon)?.defaultPort;
}
