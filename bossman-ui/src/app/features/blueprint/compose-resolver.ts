/**
 * The resolver — the honest heart of the whole idea.
 *
 * Compose does NOT actually solve variable wiring; it *dodges* it. `DB_HOST=db`
 * works only because Docker's embedded DNS resolves a service name inside the same
 * network. For a NATIVE service, or across hosts, that DNS does not exist — so
 * somebody has to turn the service name into the real address of the placed
 * service. That somebody is this file.
 *
 * The prototype resolves read-only (it renders a preview, it never writes to a
 * host), and it is deliberately explicit about what it CANNOT resolve yet — an
 * unplaced service yields `unresolved`, not a plausible-looking lie.
 */
import { Blueprint, BlueprintService } from './compose-model';

export type ResolutionState = 'literal' | 'resolved' | 'unresolved';

export interface ResolvedVar {
  key: string;
  /** the value as authored (may contain ${refs}) */
  raw: string;
  /** what it resolves to, or '' when unresolved */
  value: string;
  state: ResolutionState;
  /** which service this value comes from, when it was auto-wired */
  from?: string;
  /** why it could not be resolved (shown in the inspector) */
  note?: string;
}

/**
 * How a service is addressed by its peers — three honest mechanisms, in the order
 * a planner would reach for them:
 *
 *  1. **docker** → the compose service name. Docker's embedded DNS resolves it
 *     inside the shared network; nothing for us to do.
 *  2. **native, address planned** (`x-yolo-address`) → that IP/FQDN. Addressing a
 *     native service is a PLANNING decision: the IP is allocated up front in IPAM
 *     (NetBox) and, where the tenant runs a managed BIND — the product already has
 *     the BIND-zones snap-in and the install-bind9 role — the DNS name for the
 *     service is created from it, so the compose service name becomes a real name.
 *  3. **native, host known but no address** → the host name is the best we have.
 *  4. **native, nothing planned** → genuinely unknowable. Say so instead of
 *     inventing something plausible; the address is the author's next decision.
 */
export function addressOf(s: BlueprintService): { address: string; state: ResolutionState; note?: string } {
  if (s.kind === 'docker') {
    return { address: s.name, state: 'resolved', note: 'Compose-DNS im gemeinsamen Netz' };
  }
  if (s.address) {
    return { address: s.address, state: 'resolved', note: 'geplante Adresse (IPAM/NetBox; DNS-Name via verwaltetes BIND)' };
  }
  if (s.host) return { address: s.host, state: 'resolved', note: 'platzierter Host (x-yolo-host)' };
  return {
    address: '',
    state: 'unresolved',
    note: 'native Dienst ohne geplante Adresse — Compose-DNS greift hier nicht: IP in IPAM (NetBox) vergeben, DNS-Name über das verwaltete BIND anlegen',
  };
}

const REF_RE = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g;

/**
 * Resolve one service's environment. Two things happen:
 *  1. `${OTHER}`/`$OTHER` references are substituted from the same service's env
 *     (plain Compose interpolation semantics).
 *  2. A value that is exactly another service's NAME (which is how Compose
 *     addresses a peer, and what auto-wiring writes) is resolved to that peer's
 *     real address — the step Compose leaves to Docker's DNS.
 */
export function resolveService(bp: Blueprint, svc: BlueprintService): ResolvedVar[] {
  const byName = new Map(bp.services.map((s) => [s.name, s]));
  const out: ResolvedVar[] = [];

  for (const [key, raw] of Object.entries(svc.environment)) {
    const from = svc.bindings[key];

    // (2) the value names a peer service → resolve it to that peer's address
    const peer = byName.get(raw.trim());
    if (peer && peer.name !== svc.name) {
      const { address, state, note } = addressOf(peer);
      out.push({
        key, raw, value: address, state,
        from: from ?? peer.name,
        note: state === 'resolved' ? `→ ${address} (${note})` : note,
      });
      continue;
    }

    // (1) interpolate ${...} refs against this service's own env
    if (REF_RE.test(raw)) {
      REF_RE.lastIndex = 0;
      let unresolvedRef = '';
      const value = raw.replace(REF_RE, (_m, a: string, b: string) => {
        const name = a ?? b;
        const hit = svc.environment[name];
        if (hit === undefined) { unresolvedRef = name; return ''; }
        return hit;
      });
      out.push(unresolvedRef
        ? { key, raw, value: '', state: 'unresolved', from, note: `\${${unresolvedRef}} ist nirgends gesetzt` }
        : { key, raw, value, state: 'resolved', from, note: 'Compose-Interpolation' });
      continue;
    }

    out.push({ key, raw, value: raw, state: 'literal', from });
  }

  return out.sort((a, b) => a.key.localeCompare(b.key));
}

/** Every service's resolution, keyed by service name — the "was würde passieren"
 * preview for the whole blueprint. */
export function resolveBlueprint(bp: Blueprint): Record<string, ResolvedVar[]> {
  const out: Record<string, ResolvedVar[]> = {};
  for (const s of bp.services) out[s.name] = resolveService(bp, s);
  return out;
}

/**
 * `depends_on` start order — a topological sort. This is what a graph-wide rollout
 * would iterate (today nothing in the product reads System.edges at all), and it is
 * also how the editor reports a dependency cycle back to the author.
 */
export function startOrder(bp: Blueprint): { order: string[]; cycle: string[] } {
  const names = bp.services.map((s) => s.name);
  const deps = new Map(bp.services.map((s) => [s.name, s.dependsOn.filter((d) => names.includes(d))]));
  const order: string[] = [];
  const state = new Map<string, 'open' | 'doing' | 'done'>(names.map((n) => [n, 'open']));
  let cycle: string[] = [];

  const visit = (n: string, path: string[]): void => {
    if (state.get(n) === 'done') return;
    if (state.get(n) === 'doing') { if (!cycle.length) cycle = [...path.slice(path.indexOf(n)), n]; return; }
    state.set(n, 'doing');
    for (const d of deps.get(n) ?? []) visit(d, [...path, n]);
    state.set(n, 'done');
    order.push(n);
  };
  for (const n of names) visit(n, []);
  return { order, cycle };
}
