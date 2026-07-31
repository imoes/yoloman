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
   * IP is allocated up front in the IPAM of record and, where the tenant runs a managed
   * BIND (the `pkg-bind` snap-in / the install-bind9 role), the DNS name is created
   * from it. Empty = still to be planned.
   */
  address?: string;
  /** x-yolo-template — config template that renders this service's config */
  template?: string;
  /**
   * compose `environment` — real environment variables. Keys MUST be POSIX env
   * names; this is where wiring variables (DB_HOST…) and a container's own env live.
   */
  environment: Record<string, string>;
  /**
   * x-yolo-values — the CONFIG TEMPLATE's values for a native service, keyed by
   * DIRECTIVE. Deliberately not `environment`: a mined config schema is keyed by
   * directive name, and 2209 of 29972 catalogue fields are things like
   * `devices.sysfs_scan` or `feeds.items.url`, which are perfectly good directives
   * and invalid environment variables. Conflating the two produced a compose file no
   * runtime could apply (found by scripts/stress-blueprint.ts).
   */
  values: Record<string, string>;
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
  /**
   * Which package-catalog categories this component can be. Placing a "Datenbank"
   * must only offer database roles — the catalog already carries a `category` per
   * package (database/web/network/storage/security/system/time/virtualization/
   * services), so we filter against that instead of inventing a second taxonomy.
   * Empty = no restriction (a generic Server can take any role).
   */
  categories?: string[];
  /**
   * Capabilities this component OFFERS to others — the `provides` half of the
   * plausibility model. A consumer may only be wired to a target that provides
   * one of the capabilities the consumer `requires`. Tokens are free strings; we
   * seed them at the category grain (`database`, `web`, `cache`, `queue`) so the
   * data is present with no catalog mining, and a later pass can add role-grain
   * tokens (`postgresql`) for finer matching (see compose-wiring.capabilityMatch).
   */
  provides?: string[];
  /**
   * Capabilities this component NEEDS — the `requires` half. These become the
   * open dependency slots shown when the role is placed, and an edge is only
   * plausible when its target provides one of them. A generic Server requires
   * nothing until a role is chosen.
   */
  requires?: string[];
}

// provides/requires below are a SEEDED default taxonomy for the archetypes — sensible starting
// capabilities, not a final vocabulary. The token set is the operator's to own; this is the smallest
// set that makes the common stacks (web→database, lb→web, app→cache/queue) plausibility-checkable
// today, and is meant to be reviewed and extended (role-grain tokens like `postgresql` come later).
export const PALETTE: PaletteEntry[] = [
  // A generic Server/Container provides and requires nothing until a role is chosen — it can host
  // anything, so it must not constrain wiring on its own.
  { icon: 'server', label: 'Server', kind: 'native', prefix: 'srv' },
  { icon: 'container', label: 'Container', kind: 'docker', prefix: 'app' },
  { icon: 'database', label: 'Datenbank', kind: 'native', prefix: 'db', defaultPort: 5432, categories: ['database'], provides: ['database'] },
  { icon: 'proxy', label: 'Webserver / Proxy', kind: 'native', prefix: 'web', defaultPort: 80, categories: ['web'], provides: ['web'], requires: ['database'] },
  { icon: 'loadbalancer', label: 'Load Balancer', kind: 'native', prefix: 'lb', defaultPort: 80, categories: ['web', 'network'], provides: ['web'], requires: ['web'] },
  { icon: 'cache', label: 'Cache', kind: 'docker', prefix: 'cache', defaultPort: 6379, categories: ['database'], provides: ['cache'] },
  { icon: 'queue', label: 'Message Queue', kind: 'docker', prefix: 'mq', defaultPort: 5672, categories: ['services', 'database'], provides: ['queue'] },
  { icon: 'storage', label: 'Storage', kind: 'native', prefix: 'store', categories: ['storage'], provides: ['storage'] },
  { icon: 'firewall', label: 'Firewall', kind: 'native', prefix: 'fw', categories: ['security', 'network'] },
  { icon: 'k8s', label: 'Kubernetes', kind: 'docker', prefix: 'k8s', categories: ['virtualization'] },
  { icon: 'network', label: 'Netz', kind: 'native', prefix: 'net', categories: ['network'], provides: ['network'] },
  { icon: 'external', label: 'Externer Dienst', kind: 'native', prefix: 'ext' },
  { icon: 'agent', label: 'Agent', kind: 'native', prefix: 'agent', categories: ['system'] },
  { icon: 'hypervisor', label: 'Hypervisor', kind: 'native', prefix: 'hv', categories: ['virtualization'], provides: ['virtualization'] },
  { icon: 'template', label: 'VM-Template', kind: 'native', prefix: 'tmpl', categories: ['virtualization'], requires: ['virtualization'] },
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
 * practice: service `db` is reachable as host `db`, so its vars are DB_*.
 *
 * A compose service name may legally start with a digit (DNS labels may, RFC 1123)
 * but an environment variable may NOT — POSIX requires `[A-Za-z_][A-Za-z0-9_]*`. The
 * catalogue really contains such packages (0install, 2ping, 389-ds, …), which would
 * otherwise yield an unusable `0INSTALL_HOST`, so a leading digit gets an underscore
 * in front. Found by scripts/stress-blueprint.ts over all templates. */
export function envPrefix(serviceName: string): string {
  const upper = serviceName.toUpperCase().replace(/[^A-Z0-9]+/g, '_');
  return /^[0-9]/.test(upper) ? `_${upper}` : upper;
}

/** Is `key` usable as a real environment variable (POSIX name)? A template's schema
 * field is NOT automatically one — mined config schemas contain dotted directive
 * names such as `devices.sysfs_scan` (lvm.conf) — so anything rendered into
 * `environment:` has to be checked rather than assumed. */
export function isValidEnvName(key: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(key);
}
