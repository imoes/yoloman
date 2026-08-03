import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { MatTabsModule } from '@angular/material/tabs';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { ParamFormComponent } from '../param-form/param-form.component';
import { ParamSchema } from '../param-form/param-form.types';
import {
  ResourceDiff, ResourceGeneration, ResourceRef, ResourceService,
} from '../../core/services/resource.service';

/**
 * The ONE inspector for any Resource — its tabs ARE the protocol verbs (docs/ui-workspaces.md,
 * docs/resource-protocol.md):
 *
 *   Values      ← schema()      (rendered by app-param-form)
 *   State       ← observe()     (what IS on the host)
 *   Preview     ← plan(desired) (what WOULD change)
 *   Generations ← apply()/rollback()  (history + undo)
 *
 * There is deliberately NO kind-specific code in here: a config file, a container, a Helm release and a
 * role all answer the same verbs, so adding a kind is a backend implementation plus a descriptor — never a
 * new panel. That is the OOP payoff made visible in the UI.
 */
@Component({
  selector: 'app-resource-inspector',
  standalone: true,
  imports: [MatTabsModule, MatButtonModule, MatIconModule, ParamFormComponent],
  template: `
    <div class="bm-ri">
      <div class="bm-ri-head">
        <span class="bm-ri-kind">{{ ref().kind }}</span>
        <strong class="bm-ri-name">{{ ref().name }}</strong>
        @if (busy()) { <span class="bm-ri-busy">working…</span> }
        @if (error(); as e) { <span class="bm-ri-err">{{ e }}</span> }
      </div>

      <mat-tab-group>
        <!-- schema() -->
        <mat-tab label="Values"><ng-template matTabContent>
          <div class="bm-ri-tab">
            @if (schemaFields(); as sch) {
              <app-param-form [params]="sch" [initial]="observed() ?? {}" [agentId]="ref().agentId"
                              (valuesChange)="desired.set($event)" />
            } @else {
              <p class="bm-ri-dim">This kind derives its fields from its codec instead of a static schema —
                edit it in its own editor; State, Preview and Generations still apply here.</p>
            }
          </div>
        </ng-template></mat-tab>

        <!-- observe() -->
        <mat-tab label="State"><ng-template matTabContent>
          <div class="bm-ri-tab">
            @if (observed(); as st) {
              <table class="bm-ri-kv">
                @for (row of entries(st); track row[0]) {
                  <tr><td class="bm-ri-k">{{ row[0] }}</td><td class="bm-ri-v">{{ fmt(row[1]) }}</td></tr>
                }
              </table>
            } @else {
              <p class="bm-ri-dim">Not present on the host yet — an apply would create it.</p>
            }
          </div>
        </ng-template></mat-tab>

        <!-- plan() -->
        <mat-tab label="Preview"><ng-template matTabContent>
          <div class="bm-ri-tab">
            <button mat-stroked-button (click)="preview()" [disabled]="busy()">
              <mat-icon>difference</mat-icon> Preview changes
            </button>
            @if (diff(); as d) {
              <p class="bm-ri-action">{{ d.action }} · {{ d.changed_count }} field(s)</p>
              @if (d.action === 'noop') {
                <p class="bm-ri-dim">Already in the desired state — nothing to apply.</p>
              } @else {
                <table class="bm-ri-kv">
                  @for (row of entries(d.changed); track row[0]) {
                    <tr>
                      <td class="bm-ri-k">{{ row[0] }}</td>
                      <td class="bm-ri-v"><s class="bm-ri-old">{{ fmt(asPair(row[1])[0]) }}</s>
                        → <span class="bm-ri-new">{{ fmt(asPair(row[1])[1]) }}</span></td>
                    </tr>
                  }
                </table>
                <button mat-stroked-button class="bm-ri-apply" (click)="apply()" [disabled]="busy()">
                  <mat-icon>play_arrow</mat-icon> Apply
                </button>
              }
            }
          </div>
        </ng-template></mat-tab>

        <!-- apply() history + rollback() -->
        <mat-tab label="Generations"><ng-template matTabContent>
          <div class="bm-ri-tab">
            @if (generations().length) {
              <table class="bm-ri-gen">
                @for (g of generations(); track g.generation) {
                  <tr>
                    <td class="bm-ri-k">#{{ g.generation }}</td>
                    <td class="bm-ri-v">{{ g.note || '—' }}</td>
                    <td class="bm-ri-v bm-ri-dim">{{ g.created_at || '' }}</td>
                    <td><button mat-button (click)="rollback(g.generation)" [disabled]="busy()">Restore</button></td>
                  </tr>
                }
              </table>
            } @else {
              <p class="bm-ri-dim">No recorded applies yet. Every apply records a generation, and a
                generation is what Restore brings back.</p>
            }
          </div>
        </ng-template></mat-tab>
      </mat-tab-group>
    </div>
  `,
  styles: [`
    .bm-ri { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; }
    .bm-ri-head { display: flex; align-items: center; gap: 8px; padding: 9px 12px;
      border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-ri-kind { font-size: 10.5px; text-transform: uppercase; letter-spacing: .05em; opacity: .55;
      font-family: ui-monospace, monospace; }
    .bm-ri-name { font-size: 13px; font-family: ui-monospace, monospace; }
    .bm-ri-busy { font-size: 11.5px; opacity: .6; }
    .bm-ri-err { font-size: 11.5px; color: var(--mat-sys-error, #c62828); }
    .bm-ri-tab { padding: 12px; }
    .bm-ri-dim { opacity: .6; font-size: 12.5px; }
    .bm-ri-action { font-size: 12px; font-family: ui-monospace, monospace; margin: 10px 0 6px; }
    .bm-ri-kv, .bm-ri-gen { width: 100%; border-collapse: collapse; font-size: 12.5px; }
    .bm-ri-kv td, .bm-ri-gen td { padding: 4px 6px; border-top: 1px solid var(--mat-sys-outline-variant);
      vertical-align: top; }
    .bm-ri-k { font-family: ui-monospace, monospace; opacity: .7; white-space: nowrap; width: 1%; }
    .bm-ri-v { word-break: break-word; }
    .bm-ri-old { opacity: .55; }
    .bm-ri-new { color: var(--bm-green, #1e9600); }
    .bm-ri-apply { margin-top: 10px; }
  `],
})
export class ResourceInspectorComponent {
  private svc = inject(ResourceService);

  /** Which resource to inspect. Changing it reloads everything. */
  ref = input.required<ResourceRef>();

  schema = signal<ParamSchema | null>(null);
  observed = signal<Record<string, unknown> | null>(null);
  diff = signal<ResourceDiff | null>(null);
  generations = signal<ResourceGeneration[]>([]);
  desired = signal<Record<string, unknown>>({});
  busy = signal(false);
  error = signal('');

  /** null when the kind has no static schema (config) — the Values tab then explains itself. */
  schemaFields = computed(() => {
    const s = this.schema();
    return s && Object.keys(s).length ? s : null;
  });

  constructor() {
    // One reload per ref. Writes land in async callbacks, so this stays effect-safe.
    effect(() => {
      const r = this.ref();
      this.schema.set(null); this.observed.set(null); this.diff.set(null);
      this.generations.set([]); this.error.set('');
      this.svc.schema(r).subscribe({ next: (s) => this.schema.set(s), error: () => this.schema.set(null) });
      this.svc.observe(r).subscribe({
        next: (st) => this.observed.set(st),
        error: (e) => this.error.set(this.msg(e)),
      });
      this.svc.generations(r).subscribe({ next: (g) => this.generations.set(g || []), error: () => this.generations.set([]) });
    });
  }

  /** Object.entries for the template (Angular templates cannot call Object directly). */
  entries(o: Record<string, unknown> | null | undefined): [string, unknown][] {
    return o ? Object.entries(o) : [];
  }
  /** A diff entry is [old, new]; narrow it for the template. */
  asPair(v: unknown): [unknown, unknown] {
    return Array.isArray(v) ? [v[0], v[1]] : [undefined, v];
  }
  fmt(v: unknown): string {
    if (v == null) return '—';
    return typeof v === 'object' ? JSON.stringify(v) : String(v);
  }
  private msg(e: unknown): string {
    const err = e as { error?: { detail?: string }; message?: string };
    return err?.error?.detail || err?.message || 'request failed';
  }

  preview(): void {
    this.busy.set(true); this.error.set('');
    this.svc.plan(this.ref(), this.desired()).subscribe({
      next: (d) => { this.diff.set(d); this.busy.set(false); },
      error: (e) => { this.error.set(this.msg(e)); this.busy.set(false); },
    });
  }

  apply(): void {
    this.busy.set(true); this.error.set('');
    this.svc.apply(this.ref(), this.desired(), false).subscribe({
      next: (res) => {
        this.busy.set(false);
        if (res.ok === false) { this.error.set(res.error || 'apply failed'); return; }
        this.refreshAfterWrite();
      },
      error: (e) => { this.error.set(this.msg(e)); this.busy.set(false); },
    });
  }

  rollback(generation: number): void {
    this.busy.set(true); this.error.set('');
    this.svc.rollback(this.ref(), generation).subscribe({
      next: () => { this.busy.set(false); this.refreshAfterWrite(); },
      error: (e) => { this.error.set(this.msg(e)); this.busy.set(false); },
    });
  }

  /** After a write the host's state and the generation list both moved — re-read both, and drop the stale
   *  diff so the Preview tab cannot show a plan that was already applied. */
  private refreshAfterWrite(): void {
    const r = this.ref();
    this.diff.set(null);
    this.svc.observe(r).subscribe({ next: (st) => this.observed.set(st), error: () => {} });
    this.svc.generations(r).subscribe({ next: (g) => this.generations.set(g || []), error: () => {} });
  }
}
