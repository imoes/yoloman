import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { Agent } from '../../core/models/agent.model';
import { CheckCatalogEntry, CheckOption, EffectiveCheck } from '../../core/models/check.model';
import { CheckService } from '../../core/services/check.service';

/**
 * Block G9-P2 — the host's Checks tab. Shows the checks that effectively
 * apply to this host (resolved GPO-style from OU/group/host assignments),
 * where each check's warn levels come from — and lets you add a check to
 * this host or override an inherited one's parameters right here (the "few
 * clicks, on the host page" model the user asked for). Group/OU-wide
 * assignment stays in OU/Policy; this tab is the host-centric view + host
 * overrides.
 */
@Component({
  selector: 'app-host-checks',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatIconModule, MatFormFieldModule, MatInputModule, MatSelectModule],
  template: `
    <div class="bm-checks">
      @if (error()) { <div class="bm-error">{{ error() }}</div> }

      <div class="bm-add">
        <mat-form-field appearance="outline" class="bm-ff">
          <mat-label>Add a check to this host</mat-label>
          <mat-select [(ngModel)]="pickName" (ngModelChange)="onPick($event)">
            @for (c of addable(); track c.name) {
              <mat-option [value]="c.name">{{ c.name }}{{ c.short_description ? ' — ' + c.short_description : '' }}</mat-option>
            }
          </mat-select>
        </mat-form-field>
      </div>

      @if (pickName()) {
        <div class="bm-form">
          <div class="bm-form-title">Configure <b>{{ pickName() }}</b> for {{ agent().name }}</div>
          @for (o of pickOptions(); track o.key) {
            <mat-form-field appearance="outline" class="bm-ff">
              <mat-label>{{ o.key }}{{ o.spec.required ? ' *' : '' }}</mat-label>
              <input matInput [ngModel]="draft()[o.key]" (ngModelChange)="setDraft(o.key, $event)"
                     [placeholder]="o.spec.description || o.spec.type || ''" />
            </mat-form-field>
          }
          @if (!pickOptions().length) {
            <p class="bm-dim">This check has no parameters — assign it as-is.</p>
          }
          <div class="bm-form-actions">
            <button mat-raised-button color="primary" (click)="assign()">Assign to host</button>
            <button mat-button (click)="cancel()">Cancel</button>
          </div>
        </div>
      }

      <h3>Effective checks</h3>
      @if (checks().length) {
        <table class="bm-table">
          <thead><tr><th>Check</th><th>From</th><th>Parameters</th><th></th></tr></thead>
          <tbody>
            @for (c of checks(); track c.check_name) {
              <tr [class.bm-orphan]="!c.in_library">
                <td class="bm-mono">{{ c.check_name }}<div class="bm-dim bm-sd">{{ c.short_description }}</div></td>
                <td><span class="bm-scope bm-scope-{{ c.source_scope }}">{{ scopeLabel(c) }}</span></td>
                <td class="bm-dim bm-params">{{ paramsSummary(c.parameters) }}</td>
                <td class="bm-actions">
                  @if (c.source_scope === 'host') {
                    <button mat-button (click)="remove(c)">Remove</button>
                  } @else {
                    <button mat-button (click)="override(c)">Override here</button>
                  }
                </td>
              </tr>
            }
          </tbody>
        </table>
      } @else {
        <p class="bm-dim">No checks apply to this host yet. Add one above, or assign a check to its OU/group in OU&nbsp;/&nbsp;Policy.</p>
      }
    </div>
  `,
  styles: [
    `
      .bm-checks { padding: 4px 2px; }
      .bm-add, .bm-form { margin-bottom: 12px; }
      .bm-ff { width: 320px; max-width: 100%; margin-right: 12px; }
      .bm-form { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 12px 14px; }
      .bm-form-title { margin-bottom: 8px; }
      .bm-form-actions { display: flex; gap: 8px; margin-top: 4px; }
      .bm-table { width: 100%; border-collapse: collapse; }
      .bm-table th { text-align: left; opacity: 0.6; font-weight: 500; padding: 4px 10px 4px 0; }
      .bm-table td { padding: 6px 10px 6px 0; border-top: 1px solid var(--mat-sys-outline-variant); vertical-align: top; }
      .bm-mono { font-family: monospace; }
      .bm-sd { font-size: 11.5px; }
      .bm-dim { opacity: 0.6; }
      .bm-params { font-family: monospace; font-size: 12px; }
      .bm-scope { font-size: 11px; padding: 1px 8px; border-radius: 999px; }
      .bm-scope-host { background: color-mix(in srgb, var(--bm-green) 22%, transparent); }
      .bm-scope-group { background: color-mix(in srgb, var(--bm-gold, #caa300) 26%, transparent); }
      .bm-scope-ou { background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
      .bm-orphan { opacity: 0.55; }
      .bm-error { color: #d32f2f; margin-bottom: 10px; }
      h3 { margin: 14px 0 6px; font-size: 13px; opacity: 0.8; }
    `,
  ],
})
export class HostChecksComponent {
  private checkService = inject(CheckService);
  agent = input.required<Agent>();

  checks = signal<EffectiveCheck[]>([]);
  catalog = signal<CheckCatalogEntry[]>([]);
  error = signal<string | null>(null);

  pickName = signal<string>('');
  draft = signal<Record<string, string>>({});

  /** Checks in the library not already effective on this host. */
  addable = computed(() => {
    const have = new Set(this.checks().map((c) => c.check_name));
    return this.catalog().filter((c) => !have.has(c.name));
  });

  pickOptions = computed<{ key: string; spec: CheckOption }[]>(() => {
    const c = this.catalog().find((x) => x.name === this.pickName());
    if (!c) return [];
    return Object.entries(c.options || {}).map(([key, spec]) => ({ key, spec }));
  });

  constructor() {
    // Reload whenever the bound agent changes (tab opened / host switched).
    effect(() => {
      const a = this.agent();
      if (a?.id) this.reload(a.id);
    });
  }

  private reload(agentId: string): void {
    this.checkService.effectiveHostChecks(agentId).subscribe({
      next: (r) => this.checks.set(r.checks),
      error: (e) => this.fail(e),
    });
    this.checkService.listChecks().subscribe({ next: (r) => this.catalog.set(r.checks) });
  }

  private fail(e: unknown): void {
    const d = (e as { error?: { detail?: string }; message?: string })?.error?.detail;
    this.error.set(d ?? (e as { message?: string })?.message ?? 'Request failed');
  }

  scopeLabel(c: EffectiveCheck): string {
    if (c.source_scope === 'host') return 'host';
    if (c.source_scope === 'group') return 'group';
    return 'OU';
  }

  paramsSummary(params: Record<string, unknown>): string {
    const keys = Object.keys(params || {});
    if (!keys.length) return '(defaults)';
    return keys.map((k) => `${k}=${JSON.stringify(params[k])}`).join(', ');
  }

  onPick(name: string): void {
    this.pickName.set(name);
    // Seed the draft with each option's default (as a string for the input).
    const c = this.catalog().find((x) => x.name === name);
    const d: Record<string, string> = {};
    for (const [k, spec] of Object.entries(c?.options || {})) {
      if (spec.default !== undefined && spec.default !== null) d[k] = String(spec.default);
    }
    this.draft.set(d);
  }

  setDraft(key: string, value: string): void {
    this.draft.update((d) => ({ ...d, [key]: value }));
  }

  cancel(): void {
    this.pickName.set('');
    this.draft.set({});
  }

  /** Coerce the string form values to typed params per the option's type. */
  private typedParams(name: string): Record<string, unknown> {
    const c = this.catalog().find((x) => x.name === name);
    const opts = c?.options || {};
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(this.draft())) {
      if (v === '' || v == null) continue;
      const t = (opts[k]?.type || '').toLowerCase();
      if (t === 'int' || t === 'integer') out[k] = parseInt(v, 10);
      else if (t === 'float' || t === 'number') out[k] = parseFloat(v);
      else if (t === 'bool' || t === 'boolean') out[k] = v === 'true' || v === '1' || v === 'yes';
      else out[k] = v;
    }
    return out;
  }

  assign(): void {
    const name = this.pickName();
    if (!name) return;
    this.error.set(null);
    this.checkService
      .createAssignment({ check_name: name, scope_type: 'host', agent_id: this.agent().id, parameters: this.typedParams(name) })
      .subscribe({
        next: () => { this.cancel(); this.reload(this.agent().id); },
        error: (e) => this.fail(e),
      });
  }

  /** Create a host-scoped override starting from the inherited params. */
  override(c: EffectiveCheck): void {
    this.pickName.set(c.check_name);
    const d: Record<string, string> = {};
    for (const [k, v] of Object.entries(c.parameters || {})) d[k] = String(v);
    this.draft.set(d);
  }

  remove(c: EffectiveCheck): void {
    this.checkService.deleteAssignment(c.assignment_id).subscribe({
      next: () => this.reload(this.agent().id),
      error: (e) => this.fail(e),
    });
  }
}
