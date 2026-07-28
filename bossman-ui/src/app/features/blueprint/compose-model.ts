/**
 * The blueprint's data model — deliberately NOT a bespoke graph format.
 *
 * A blueprint IS a Docker Compose document (compose-spec.io): `services` are the
 * components, `environment` holds the variables, `ports` the exposed interfaces,
 * `depends_on` the edges (including start order). We reuse that grammar instead of
 * inventing a provides/requires model — see the plan's "warum das Rad zweimal
 * erfinden".
 *
 * Compose is single-host and image-centric, so the two things it cannot express
 * for a NATIVE service ride in the `x-`extension fields the spec sanctions
 * (the document therefore stays valid Compose):
 *   x-yolo-kind      native | docker
 *   x-yolo-host      which agent/host the service is placed on (Compose has no placement)
 *   x-yolo-role      the role instead of `image:` (native = package + config template + unit)
 *   x-yolo-template  which configs/config_templates/<name> renders its config
 *   x-yolo-layout    {x,y} canvas position (editor-only; ignored by Compose itself)
 *   x-yolo-bindings  {envKey: sourceService} — provenance of auto-wired variables
 */

/** Which tier a service runs on. The prototype covers the two that matter for
 * the "server or container" question; k8s/vm fold in later behind the same doc. */
export type ServiceKind = 'native' | 'docker';

/** One node on the canvas == one entry under compose `services:`. */
export interface BlueprintService {
  /** the compose service key — also the DNS name other services address it by */
  name: string;
  kind: ServiceKind;
  /** palette icon key → assets/blueprint/<icon>.svg */
  icon: string;
  /** native: the role (a wizard runbook name, e.g. "install-postgresql") */
  role?: string;
  /** docker: the image reference */
  image?: string;
  /** x-yolo-host — the placed host; empty = not placed yet */
  host?: string;
  /**
   * x-yolo-address — the PLANNED address (IP or FQDN) this service is reachable at.
   * Addressing a native service is a planning decision, not a runtime accident: the
   * IP is allocated up front (IPAM, e.g. NetBox) and, where the tenant runs a managed
   * BIND (the `pkg-bind` snap-in / the install-bind9 role), the DNS name is created
   * from it. Empty = still to be planned.
   */
  address?: string;
  /** x-yolo-template — config template that renders this service's config */
  template?: string;
  /** compose `environment` — the variables (values, or ${refs}) */
  environment: Record<string, string>;
  /** compose `ports` — "host:container" strings, kept verbatim */
  ports: string[];
  /** compose `depends_on` — the edges */
  dependsOn: string[];
  /** which env keys were auto-wired, and from which service (x-yolo-bindings) */
  bindings: Record<string, string>;
  /** canvas position (x-yolo-layout) */
  x: number;
  y: number;
}

export interface Blueprint {
  /** compose top-level `name:` */
  name: string;
  services: BlueprintService[];
}

/** A palette entry: what you can drop on the canvas. `kind` preselects the tier,
 * `icon` picks the vendored SVG. Order = palette order. */
export interface PaletteEntry {
  icon: string;
  label: string;
  kind: ServiceKind;
  /** suggested compose service name prefix */
  prefix: string;
  /** default container port, used when auto-wiring a consumer's <NAME>_PORT */
  defaultPort?: number;
}

export const PALETTE: PaletteEntry[] = [
  { icon: 'server', label: 'Server', kind: 'native', prefix: 'srv' },
  { icon: 'container', label: 'Container', kind: 'docker', prefix: 'app' },
  { icon: 'database', label: 'Datenbank', kind: 'native', prefix: 'db', defaultPort: 5432 },
  { icon: 'proxy', label: 'Webserver / Proxy', kind: 'native', prefix: 'web', defaultPort: 80 },
  { icon: 'loadbalancer', label: 'Load Balancer', kind: 'native', prefix: 'lb', defaultPort: 80 },
  { icon: 'cache', label: 'Cache', kind: 'docker', prefix: 'cache', defaultPort: 6379 },
  { icon: 'queue', label: 'Message Queue', kind: 'docker', prefix: 'mq', defaultPort: 5672 },
  { icon: 'storage', label: 'Storage', kind: 'native', prefix: 'store' },
  { icon: 'firewall', label: 'Firewall', kind: 'native', prefix: 'fw' },
  { icon: 'k8s', label: 'Kubernetes', kind: 'docker', prefix: 'k8s' },
  { icon: 'network', label: 'Netz', kind: 'native', prefix: 'net' },
  { icon: 'external', label: 'Externer Dienst', kind: 'native', prefix: 'ext' },
  { icon: 'agent', label: 'Agent', kind: 'native', prefix: 'agent' },
  { icon: 'hypervisor', label: 'Hypervisor', kind: 'native', prefix: 'hv' },
  { icon: 'template', label: 'VM-Template', kind: 'native', prefix: 'tmpl' },
];

export const ICON_KEYS = PALETTE.map((p) => p.icon);

export function paletteFor(icon: string): PaletteEntry | undefined {
  return PALETTE.find((p) => p.icon === icon);
}

/** Compose service names must be DNS-ish: lowercase, no underscores at the edges.
 * Used for both the generated default name and for validating a rename. */
export function sanitizeServiceName(raw: string): string {
  return raw.toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
}

/** The env-variable prefix a consumer uses to address `service` — plain Compose
 * practice: service `db` is reachable as host `db`, so its vars are DB_*. */
export function envPrefix(serviceName: string): string {
  return serviceName.toUpperCase().replace(/[^A-Z0-9]+/g, '_');
}
