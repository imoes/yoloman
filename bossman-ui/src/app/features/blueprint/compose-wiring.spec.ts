import { BlueprintService, RoleContract } from './compose-model';
import { capabilityMatch, openRequirementCaps, wireEdge } from './compose-wiring';

/** Minimal node builder — only the fields the wiring logic reads. */
function svc(name: string, icon: string, caps?: RoleContract): BlueprintService {
  return {
    name, icon, kind: 'native', environment: {}, values: {}, ports: [],
    dependsOn: [], bindings: {}, x: 0, y: 0, caps,
  };
}

const PG: RoleContract = { provides: [{ capability: 'database', backend: 'postgresql', default_port: 5432 }], requires: [] };
const MARIADB: RoleContract = { provides: [{ capability: 'database', backend: 'mariadb', default_port: 3306 }], requires: [] };
const ROUNDCUBE: RoleContract = {
  provides: [],
  requires: [{ capability: 'database', backends: ['mysql', 'mariadb'], fields: { host: 'db_host' } }],
};

describe('compose-wiring backend-aware plausibility', () => {
  it('refuses a Postgres provider for a consumer that only accepts mysql/mariadb', () => {
    expect(capabilityMatch(svc('rc', 'proxy', ROUNDCUBE), svc('pg', 'database', PG))).toBeNull();
  });

  it('accepts a MariaDB provider for a mysql/mariadb consumer (alias-aware)', () => {
    expect(capabilityMatch(svc('rc', 'proxy', ROUNDCUBE), svc('db', 'database', MARIADB))).not.toBeNull();
  });

  it('wireEdge refuses the incompatible backend and explains why', () => {
    const res = wireEdge([svc('rc', 'proxy', ROUNDCUBE), svc('pg', 'database', PG)], 'rc', 'pg');
    expect(res.error).toContain('braucht');
    expect(res.services.find((s) => s.name === 'rc')!.dependsOn).toEqual([]);
  });

  it('wireEdge connects the compatible backend and wires the host var', () => {
    const res = wireEdge([svc('rc', 'proxy', ROUNDCUBE), svc('db', 'database', MARIADB)], 'rc', 'db');
    expect(res.error).toBeNull();
    expect(res.services.find((s) => s.name === 'rc')!.dependsOn).toContain('db');
  });

  it('open requirements clear once a compatible provider is a dependency', () => {
    const rc = { ...svc('rc', 'proxy', ROUNDCUBE), dependsOn: ['db'] };
    const db = svc('db', 'database', MARIADB);
    expect(openRequirementCaps(rc, [rc, db]).length).toBe(0);
    const rc2 = { ...svc('rc', 'proxy', ROUNDCUBE), dependsOn: ['pg'] };
    const pg = svc('pg', 'database', PG);
    expect(openRequirementCaps(rc2, [rc2, pg]).map((r) => r.capability)).toEqual(['database']);
  });

  it('falls back to archetype tokens when a node has no role contract', () => {
    // proxy archetype requires ['database'], database archetype provides ['database'] → coarse match holds
    expect(capabilityMatch(svc('web', 'proxy'), svc('db', 'database'))).toBe('database');
  });
});
