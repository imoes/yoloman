import { TestBed } from '@angular/core/testing';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { provideHttpClient } from '@angular/common/http';
import { ResourceKind, ResourceService } from './resource.service';
import { environment } from '../../../environments/environment';

/**
 * The point of these tests is the PROTOCOL, not any one kind: one generic code path has to address every
 * Resource kind correctly (docs/resource-protocol.md). If adding a kind ever needed a branch in the
 * service or the inspector, that is the regression these tests are here to catch.
 */
describe('ResourceService (generic Resource protocol client)', () => {
  let svc: ResourceService;
  let http: HttpTestingController;
  const agentId = 'a1';

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [ResourceService, provideHttpClient(), provideHttpClientTesting()],
    });
    svc = TestBed.inject(ResourceService);
    http = TestBed.inject(HttpTestingController);
  });

  afterEach(() => http.verify());

  const base = (kind: string) => `${environment.apiUrl}/agents/${agentId}/resources/${kind}`;

  it('addresses every named kind as /resources/{kind}/{name}/{verb}', () => {
    const kinds: ResourceKind[] = ['docker', 'helm', 'role'];
    for (const kind of kinds) {
      svc.observe({ agentId, kind, name: 'web' }).subscribe();
      http.expectOne(`${base(kind)}/web/observe`).flush({ resource_key: 'k', observed: { image: 'nginx' } });
    }
  });

  it('addresses config by BODY/query path, not a URL segment (a file path cannot ride in a segment)', () => {
    svc.observe({ agentId, kind: 'config', name: '/etc/nginx/nginx.conf' }).subscribe();
    const req = http.expectOne((r) => r.url === `${base('config')}/observe`);
    expect(req.request.params.get('path')).toBe('/etc/nginx/nginx.conf');
    req.flush({ resource_key: 'k', observed: {} });
  });

  it('unwraps the observe envelope so callers get the protocol VALUE', () => {
    let seen: unknown = 'unset';
    svc.observe({ agentId, kind: 'docker', name: 'web' }).subscribe((v) => (seen = v));
    http.expectOne(`${base('docker')}/web/observe`).flush({ resource_key: 'k', observed: { image: 'nginx' } });
    expect(seen).toEqual({ image: 'nginx' });
  });

  it('reports a resource that does not exist yet as null (so the UI can say "would create")', () => {
    let seen: unknown = 'unset';
    svc.observe({ agentId, kind: 'docker', name: 'web' }).subscribe((v) => (seen = v));
    http.expectOne(`${base('docker')}/web/observe`).flush({ resource_key: 'k', observed: null });
    expect(seen).toBeNull();
  });

  it('unwraps the generations envelope and tolerates a bare array', () => {
    let a: unknown[] = [];
    svc.generations({ agentId, kind: 'role', name: 'nginx' }).subscribe((g) => (a = g));
    http.expectOne(`${base('role')}/nginx/generations`).flush({ generations: [{ generation: 2, spec: {} }] });
    expect(a.length).toBe(1);

    let b: unknown[] = [];
    svc.generations({ agentId, kind: 'role', name: 'nginx' }).subscribe((g) => (b = g));
    http.expectOne(`${base('role')}/nginx/generations`).flush([{ generation: 1, spec: {} }]);
    expect(b.length).toBe(1);
  });

  it('sends the identity fields with plan/apply/rollback per kind', () => {
    svc.plan({ agentId, kind: 'config', name: '/etc/hosts' }, { values: { a: 1 } }).subscribe();
    const plan = http.expectOne(`${base('config')}/plan`);
    expect(plan.request.body.path).toBe('/etc/hosts');
    plan.flush({ action: 'noop', changed: {}, changed_count: 0 });

    svc.apply({ agentId, kind: 'helm', name: 'redis', namespace: 'prod' }, { chart: 'redis' }, false, 'note').subscribe();
    const apply = http.expectOne(`${base('helm')}/redis/apply`);
    expect(apply.request.body.namespace).toBe('prod');
    expect(apply.request.body.dry_run).toBe(false);
    expect(apply.request.body.note).toBe('note');
    apply.flush({ dry_run: false, ok: true, generation: 1 });

    svc.rollback({ agentId, kind: 'docker', name: 'web' }, 3).subscribe();
    const rb = http.expectOne(`${base('docker')}/web/rollback`);
    expect(rb.request.body.generation).toBe(3);
    rb.flush({ dry_run: false, ok: true });
  });

  it('defaults apply to a dry run, so a preview can never mutate a host by accident', () => {
    svc.apply({ agentId, kind: 'docker', name: 'web' }, { image: 'nginx' }).subscribe();
    const req = http.expectOne(`${base('docker')}/web/apply`);
    expect(req.request.body.dry_run).toBe(true);
    req.flush({ dry_run: true });
  });

  it('does not call a schema endpoint for config (it has none — fields come from its codec)', () => {
    let sch: unknown = 'unset';
    svc.schema({ agentId, kind: 'config', name: '/etc/hosts' }).subscribe((s) => (sch = s));
    expect(sch).toEqual({});
    http.expectNone(`${base('config')}/schema`);
  });
});
