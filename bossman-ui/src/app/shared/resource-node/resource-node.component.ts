import { Component, OnInit, computed, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { ParamFormComponent } from '../param-form/param-form.component';
import { ParamSchema } from '../param-form/param-form.types';
import { ApplyResult, ResourceGeneration, ResourceKind, ResourcePlan, ResourceRef, ResourceService } from '../../core/services/resource.service';
import { descriptorFor } from './resource-node-registry';

/**
 * ResourceNode — a Resource/Deployable drawing itself (docs/resource-protocol.md):
 * status (observe) + a schema-driven form + Plan (diff) / Apply, and its
 * generation history with Rollback. The reusable unit the Workflow-Designer
 * canvas will place as a node; usable standalone today. First type:
 * docker_container.
 */
@Component({
  selector: 'app-resource-node',
  standalone: true,
  imports: [MatIconModule, MatButtonModule, ParamFormComponent],
  template: `
    <div class="bm-rn">
      <div class="bm-rn-head">
        <mat-icon class="bm-rn-ic">{{ descriptor().icon }}</mat-icon>
        <span class="bm-rn-kind" [title]="descriptor().label">{{ kind() }}</span>
        <span class="bm-rn-name">{{ name() }}</span>
        @if (present()) {
          <span class="bm-rn-dot ok" title="present"></span>
          <span class="bm-dim">{{ summary() }}</span>
        } @else if (kind() === 'role' && roleLinks().length && !loading()) {
          <span class="bm-rn-dot pending" title="pending approval"></span>
          <span class="bm-dim">pending approval · {{ roleLinks()[0].status }}</span>
        } @else if (!loading()) {
          <span class="bm-rn-dot none" title="not present"></span>
          <span class="bm-dim">{{ absentText() }}</span>
        }
      </div>

      @if (loading()) { <p class="bm-dim">Reading…</p> }
      @if (err()) { <p class="bm-err">{{ err() }}</p> }

      @if (hasSchema() || kind() === 'role') {
        @if (hasSchema()) {
          <app-param-form [params]="formSchema()" [initial]="initial()" (valuesChange)="onForm($event)" />
        } @else if (kind() === 'role') {
          <p class="bm-dim">This role has no parameters — bind it as-is.</p>
        }
        <div class="bm-rn-actions">
          <button mat-stroked-button (click)="doPlan()" [disabled]="busy()"><mat-icon>difference</mat-icon> Plan</button>
          @if (kind() === 'role') {
            <button mat-raised-button color="primary" (click)="doApply()" [disabled]="busy()"><mat-icon>link</mat-icon> Bind</button>
            @if (present() || roleLinks().length) {
              <button mat-stroked-button (click)="doUnbind()" [disabled]="busy()"><mat-icon>link_off</mat-icon> Unbind</button>
            }
          } @else {
            <button mat-raised-button color="primary" (click)="doApply()" [disabled]="busy()"><mat-icon>check</mat-icon> Apply</button>
          }
        </div>
      }

      @if (plan(); as p) {
        <div class="bm-rn-plan" [class.noop]="p.action === 'noop'">
          <strong>plan: {{ p.action }}</strong>
          @for (c of changedList(p); track c.key) {
            <div class="bm-rn-change">{{ c.key }}: <code>{{ c.from }}</code> → <code>{{ c.to }}</code></div>
          }
          @if (p.action === 'noop') { <span class="bm-dim"> — nothing to change</span> }
        </div>
      }
      @if (msg()) { <p [class.bm-good]="msgOk()" [class.bm-err]="!msgOk()">{{ msg() }}</p> }

      @if (generations().length) {
        <div class="bm-rn-gens">
          <div class="bm-rn-gh">
            Generations
            @if (kind() === 'config') {
              <span class="bm-warn"> · host-scoped: a rollback reverts the whole host's config, not just this file</span>
            }
            @if (kind() === 'role') {
              <span class="bm-dim"> · applied parameter sets — rollback re-binds an earlier set (forward-converge)</span>
            }
          </div>
          @for (g of generations(); track g.generation) {
            <div class="bm-rn-gen">
              <span class="bm-rn-gn">#{{ g.generation }}</span>
              <span>{{ specSummary(g.spec) }}</span>
              @if (g.note) { <span class="bm-dim">· {{ g.note }}</span> }
              <span class="bm-dim bm-rn-gt">{{ g.created_at }}</span>
              <button mat-button (click)="doRollback(g.generation)" [disabled]="busy()">Rollback</button>
            </div>
          }
        </div>
      }
    </div>
  `,
  styles: [`
    .bm-rn { border: 1px solid var(--mat-sys-outline-variant); border-radius: 12px; padding: 14px 16px; max-width: 680px; }
    .bm-rn-head { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }
    .bm-rn-ic { font-size: 18px; width: 18px; height: 18px; opacity: 0.8; }
    .bm-rn-kind { font-size: 10.5px; padding: 1px 7px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); font-family: ui-monospace, monospace; }
    .bm-rn-name { font-weight: 600; }
    .bm-rn-dot { width: 9px; height: 9px; border-radius: 50%; display: inline-block; }
    .bm-rn-dot.ok { background: #1e9600; }
    .bm-rn-dot.pending { background: var(--bm-gold, #b8860b); }
    .bm-rn-dot.none { background: var(--mat-sys-outline, #888); }
    .bm-dim { opacity: 0.6; font-size: 12.5px; }
    .bm-err { color: var(--mat-sys-error, #c62828); }
    .bm-good { color: #1e9600; }
    .bm-rn-actions { display: flex; gap: 10px; margin: 10px 0; }
    .bm-rn-plan { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 8px 12px; margin: 8px 0; font-size: 13px; }
    .bm-rn-plan.noop { opacity: 0.7; }
    .bm-rn-change { font-size: 12.5px; margin-top: 3px; }
    .bm-rn-gens { margin-top: 12px; border-top: 1px solid var(--mat-sys-outline-variant); padding-top: 8px; }
    .bm-rn-gh { font-size: 12px; opacity: 0.7; margin-bottom: 4px; }
    .bm-warn { color: var(--bm-gold, #b8860b); }
    .bm-rn-gen { display: flex; align-items: center; gap: 10px; font-size: 12.5px; padding: 3px 0; }
    .bm-rn-gn { font-family: ui-monospace, monospace; font-weight: 600; min-width: 34px; }
    .bm-rn-gt { margin-left: auto; }
  `],
})
export class ResourceNodeComponent implements OnInit {
  private svc = inject(ResourceService);

  /** One identity object instead of four positional arguments repeated per call —
   *  the protocol addresses a resource by (host, kind, name, namespace). */
  private ref(): ResourceRef {
    return { agentId: this.agentId(), kind: this.kind() as ResourceKind,
             name: this.name(), namespace: this.namespace() };
  }
  agentId = input.required<string>();
  name = input.required<string>();
  kind = input<string>('docker');            // docker | helm | config | role
  namespace = input<string>('default');       // helm tier

  loading = signal(true);
  busy = signal(false);
  err = signal('');
  observed = signal<Record<string, unknown> | null>(null);
  schema = signal<ParamSchema>({});
  private form = signal<Record<string, unknown>>({});
  plan = signal<ResourcePlan | null>(null);
  generations = signal<ResourceGeneration[]>([]);
  msg = signal('');
  msgOk = signal(true);

  // identity fields are shown in the header / passed as inputs, not edited
  // identity/read-only fields per tier: shown in the header, not edited
  private static IDENTITY = ['name', 'namespace', 'status', 'revision', 'path', 'format', 'separator'];

  descriptor = computed(() => descriptorFor(this.kind()));
  hasSchema = computed(() => Object.keys(this.schema()).length > 0);
  // "present" means deployed/bound. For role it's the binding, not mere existence
  // of the plan (observe() returns an object even when NOT bound to this host).
  present = computed(() => {
    const o = this.observed();
    if (!o) return false;
    return this.kind() === 'role' ? !!o['bound'] : true;
  });
  absentText = computed(() => (this.kind() === 'role' ? 'not bound to this host' : 'not deployed'));
  // role: this host's direct binding links (may be active or pending_approval).
  roleLinks = computed<{ status?: string }[]>(() => (this.observed()?.['host_links'] as { status?: string }[]) || []);
  formSchema = computed<ParamSchema>(() => {
    const s = { ...this.schema() } as Record<string, unknown>;
    // config's schema is one field PER DIRECTIVE and role's is the role's own
    // parameters, so a real field named "path"/"status"/… must survive — no
    // identity strip for those tiers.
    if (this.kind() !== 'config' && this.kind() !== 'helm' && this.kind() !== 'role') {
      for (const k of ResourceNodeComponent.IDENTITY) delete s[k];
    }
    return s as ParamSchema;
  });
  initial = computed<Record<string, unknown>>(() => {
    const o = this.observed();
    if (!o) return {};
    // Where the current values live per tier: role → observed.parameters,
    // config/helm → observed.flat_values, docker → observed root.
    let src: Record<string, unknown>;
    if (this.kind() === 'role') src = (o['parameters'] as Record<string, unknown>) || {};
    else if (this.kind() === 'config' || this.kind() === 'helm') src = (o['flat_values'] as Record<string, unknown>) || {};
    else src = o;
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(this.formSchema())) if (src[k] !== undefined) out[k] = src[k];
    return out;
  });
  summary = computed(() => {
    const o = this.observed() || {};
    if (this.kind() === 'role') {
      const links = (o['host_links'] as { status?: string }[]) || [];
      const st = links.length ? links[0].status : (o['bound'] ? 'active' : '');
      const src = o['source'] ? ` · ${o['source']}` : '';
      return o['bound'] ? `bound${src}${st ? ' · ' + st : ''}` : 'not bound';
    }
    if (o['image']) return o['image'] as string;
    if (o['chart']) {
      const n = Object.keys((o['flat_values'] as object) || {}).length;
      return n ? `${o['chart']} · ${n} values` : (o['chart'] as string);
    }
    // count DIRECTIVES (flat_values), not top-level sections — an ini file would
    // otherwise report "3 keys" meaning 3 sections.
    if (o['format']) return `${o['format']} · ${Object.keys((o['flat_values'] as object) || (o['values'] as object) || {}).length} settings`;
    return '(present)';
  });

  specSummary(spec: Record<string, unknown>): string {
    if (spec['image']) return spec['image'] as string;
    if (spec['chart']) return spec['chart'] as string;
    if (spec['hash']) return `hash ${spec['hash']}`;      // config: agent generation
    if (spec['parameters']) {                              // role: applied parameter set
      const p = spec['parameters'] as Record<string, unknown>;
      const keys = Object.keys(p);
      return keys.length ? keys.map((k) => `${k}=${p[k]}`).join(', ') : '(defaults)';
    }
    return JSON.stringify(spec['values'] ?? {});
  }

  ngOnInit(): void { this.reload(); }

  private reload(): void {
    this.loading.set(true); this.err.set('');
    const [id, k, n, ns] = [this.agentId(), this.kind(), this.name(), this.namespace()];
    // config has no /schema route — its schema rides along with observe.
    if (k !== 'config') {
      this.svc.schema({ agentId: id, kind: k as ResourceKind, name: n, namespace: ns }).subscribe({
        next: (s) => this.schema.set(s ?? ({} as ParamSchema)),
        error: (e) => this.err.set(e?.error?.detail || 'schema failed'),
      });
    }
    this.svc.observe({ agentId: id, kind: k as ResourceKind, name: n, namespace: ns }).subscribe({
      next: (o) => {
        this.loading.set(false);
        this.observed.set(o);
      },
      error: (e) => { this.loading.set(false); this.err.set(e?.error?.detail || 'observe failed'); },
    });
    this.loadGenerations();
  }
  private loadGenerations(): void {
    this.svc.generations(this.ref()).subscribe({
      next: (gs) => this.generations.set(gs || []), error: () => {},
    });
  }

  onForm(v: Record<string, unknown>): void { this.form.set(v); }
  /** The body plan/apply expect. config takes its per-directive fields inside a
   * `values` envelope (ConfigSpec) — without this wrap the flat keys would land at
   * top level, `values` would be empty, and plan/apply would silently no-op. */
  private desired(): Record<string, unknown> {
    // config and helm both expose ONE FIELD PER VALUE, so the flat form has to go
    // back inside the tier's `values` envelope — posting the flat keys at top level
    // would leave `values` empty and make plan/apply silently no-op.
    if (this.kind() === 'config') return { values: this.form() };
    if (this.kind() === 'helm') return { chart: '', values: this.form() };  // chart: reused from history
    // role: the form values ARE the binding's parameters; require_approval keeps
    // the governance gate (binding lands pending_approval unless YOLO/waived).
    if (this.kind() === 'role') return { parameters: this.form(), require_approval: true };
    return this.form();
  }

  changedList(p: ResourcePlan): { key: string; from: unknown; to: unknown }[] {
    return Object.entries(p.changed || {}).map(([key, v]) => ({ key, from: v[0], to: v[1] }));
  }

  doPlan(): void {
    this.busy.set(true); this.msg.set(''); this.plan.set(null);
    this.svc.plan(this.ref(), this.desired()).subscribe({
      next: (p) => { this.busy.set(false); this.plan.set(p); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'plan failed'); },
    });
  }
  doApply(): void {
    this.busy.set(true); this.msg.set('');
    this.svc.apply(this.ref(), this.desired(), false).subscribe({
      next: (r: ApplyResult) => { this.busy.set(false); this.afterMutation(r, this.kind() === 'role' ? 'Bound' : 'Applied'); },
      error: (e) => { this.busy.set(false); this.setMsg(false, e?.error?.detail || 'apply failed'); },
    });
  }
  /** role tier: remove this host's binding (counterpart of Bind). */
  doUnbind(): void {
    this.busy.set(true); this.msg.set('');
    this.svc.unbind(this.ref()).subscribe({
      next: (r) => {
        this.busy.set(false);
        if (r.ok) { this.setMsg(true, `Unbound (${r.unbound ?? 0} link${r.unbound === 1 ? '' : 's'}).`); this.plan.set(null); this.reload(); }
        else this.setMsg(false, r.error || 'unbind failed');
      },
      error: (e) => { this.busy.set(false); this.setMsg(false, e?.error?.detail || 'unbind failed'); },
    });
  }
  doRollback(gen: number): void {
    this.busy.set(true); this.msg.set('');
    this.svc.rollback(this.ref(), gen).subscribe({
      next: (r: ApplyResult) => { this.busy.set(false); this.afterMutation(r, `Rolled back to #${gen}`); },
      error: (e) => { this.busy.set(false); this.setMsg(false, e?.error?.detail || 'rollback failed'); },
    });
  }
  private afterMutation(r: ApplyResult, ok: string): void {
    if (r.ok) {
      let m = `${ok} → generation ${r.generation}.`;
      // role: surface the governance gate honestly — a binding is only live when
      // active; otherwise it awaits approval and won't converge yet.
      if (this.kind() === 'role' && r.status) {
        m = r.status === 'active'
          ? `Bound (active) → generation ${r.generation}.`
          : `Bound — pending approval (generation ${r.generation}). It won't converge until approved.`;
      }
      this.setMsg(true, m); this.plan.set(null); this.reload();
    } else { this.setMsg(false, `Failed: ${r.error || 'unknown'}`); }
  }
  private setMsg(ok: boolean, m: string): void { this.msgOk.set(ok); this.msg.set(m); }
}
