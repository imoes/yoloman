import { Component, OnInit, computed, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { ParamFormComponent } from '../param-form/param-form.component';
import { ParamSchema } from '../param-form/param-form.types';
import { ApplyResult, ResourceGeneration, ResourcePlan, ResourcesService } from '../../core/services/resources.service';

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
        <span class="bm-rn-kind">{{ kind() }}</span>
        <span class="bm-rn-name">{{ name() }}</span>
        @if (observed()) {
          <span class="bm-rn-dot ok" title="present"></span>
          <span class="bm-dim">{{ summary() }}</span>
        } @else if (!loading()) {
          <span class="bm-rn-dot none" title="not present"></span>
          <span class="bm-dim">not deployed</span>
        }
      </div>

      @if (loading()) { <p class="bm-dim">Reading…</p> }
      @if (err()) { <p class="bm-err">{{ err() }}</p> }

      @if (hasSchema()) {
        <app-param-form [params]="formSchema()" [initial]="initial()" (valuesChange)="onForm($event)" />
        <div class="bm-rn-actions">
          <button mat-stroked-button (click)="doPlan()" [disabled]="busy()"><mat-icon>difference</mat-icon> Plan</button>
          <button mat-raised-button color="primary" (click)="doApply()" [disabled]="busy()"><mat-icon>check</mat-icon> Apply</button>
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
          <div class="bm-rn-gh">Generations</div>
          @for (g of generations(); track g.generation) {
            <div class="bm-rn-gen">
              <span class="bm-rn-gn">#{{ g.generation }}</span>
              <span>{{ specSummary(g.spec) }}</span>
              @if (g.note) { <span class="bm-dim">· {{ g.note }}</span> }
              <span class="bm-dim bm-rn-gt">{{ g.applied_at }}</span>
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
    .bm-rn-kind { font-size: 10.5px; padding: 1px 7px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); font-family: ui-monospace, monospace; }
    .bm-rn-name { font-weight: 600; }
    .bm-rn-dot { width: 9px; height: 9px; border-radius: 50%; display: inline-block; }
    .bm-rn-dot.ok { background: #1e9600; }
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
    .bm-rn-gen { display: flex; align-items: center; gap: 10px; font-size: 12.5px; padding: 3px 0; }
    .bm-rn-gn { font-family: ui-monospace, monospace; font-weight: 600; min-width: 34px; }
    .bm-rn-gt { margin-left: auto; }
  `],
})
export class ResourceNodeComponent implements OnInit {
  private svc = inject(ResourcesService);
  agentId = input.required<string>();
  name = input.required<string>();
  kind = input<string>('docker');            // docker | helm
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
  private static IDENTITY = ['name', 'namespace', 'status', 'revision'];

  hasSchema = computed(() => Object.keys(this.schema()).length > 0);
  formSchema = computed<ParamSchema>(() => {
    const s = { ...this.schema() } as Record<string, unknown>;
    for (const k of ResourceNodeComponent.IDENTITY) delete s[k];
    return s as ParamSchema;
  });
  initial = computed<Record<string, unknown>>(() => {
    const o = this.observed();
    if (!o) return {};
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(this.formSchema())) if (o[k] !== undefined) out[k] = o[k];
    return out;
  });
  summary = computed(() => {
    const o = this.observed() || {};
    return (o['image'] ?? o['chart'] ?? '(present)') as string;
  });

  specSummary(spec: Record<string, unknown>): string {
    return (spec['image'] ?? spec['chart'] ?? JSON.stringify(spec['values'] ?? {})) as string;
  }

  ngOnInit(): void { this.reload(); }

  private reload(): void {
    this.loading.set(true); this.err.set('');
    const [id, k, n, ns] = [this.agentId(), this.kind(), this.name(), this.namespace()];
    this.svc.schema(id, k, n, ns).subscribe({
      next: (s) => this.schema.set((s.schema || {}) as ParamSchema),
      error: (e) => this.err.set(e?.error?.detail || 'schema failed'),
    });
    this.svc.observe(id, k, n, ns).subscribe({
      next: (o) => { this.loading.set(false); this.observed.set(o.observed); },
      error: (e) => { this.loading.set(false); this.err.set(e?.error?.detail || 'observe failed'); },
    });
    this.loadGenerations();
  }
  private loadGenerations(): void {
    this.svc.generations(this.agentId(), this.kind(), this.name(), this.namespace()).subscribe({
      next: (r) => this.generations.set(r.generations || []), error: () => {},
    });
  }

  onForm(v: Record<string, unknown>): void { this.form.set(v); }
  private desired() { return this.form(); }

  changedList(p: ResourcePlan): { key: string; from: unknown; to: unknown }[] {
    return Object.entries(p.changed || {}).map(([key, v]) => ({ key, from: v[0], to: v[1] }));
  }

  doPlan(): void {
    this.busy.set(true); this.msg.set(''); this.plan.set(null);
    this.svc.plan(this.agentId(), this.kind(), this.name(), this.desired(), this.namespace()).subscribe({
      next: (p) => { this.busy.set(false); this.plan.set(p); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'plan failed'); },
    });
  }
  doApply(): void {
    this.busy.set(true); this.msg.set('');
    this.svc.apply(this.agentId(), this.kind(), this.name(), this.desired(), false, undefined, this.namespace()).subscribe({
      next: (r: ApplyResult) => { this.busy.set(false); this.afterMutation(r, 'Applied'); },
      error: (e) => { this.busy.set(false); this.setMsg(false, e?.error?.detail || 'apply failed'); },
    });
  }
  doRollback(gen: number): void {
    this.busy.set(true); this.msg.set('');
    this.svc.rollback(this.agentId(), this.kind(), this.name(), gen, this.namespace()).subscribe({
      next: (r: ApplyResult) => { this.busy.set(false); this.afterMutation(r, `Rolled back to #${gen}`); },
      error: (e) => { this.busy.set(false); this.setMsg(false, e?.error?.detail || 'rollback failed'); },
    });
  }
  private afterMutation(r: ApplyResult, ok: string): void {
    if (r.ok) { this.setMsg(true, `${ok} → generation ${r.generation}.`); this.plan.set(null); this.reload(); }
    else { this.setMsg(false, `Failed: ${r.error || 'unknown'}`); }
  }
  private setMsg(ok: boolean, m: string): void { this.msgOk.set(ok); this.msg.set(m); }
}
