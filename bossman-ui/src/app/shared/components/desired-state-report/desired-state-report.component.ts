import { Component, computed, input, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { CompiledHostState } from '../../../core/models/orchestration.model';

interface ThresholdRow {
  service_name?: string;
  metric: string;
  warn?: unknown;
  crit?: unknown;
  comparison?: string;
  source?: string;
}
interface PlanRow {
  name: string;
  version: number | null;
  type: string;
  source: string;
  parameters: Record<string, unknown>;
}

/**
 * gpresult-style report of a host's compiled desired_state: collapsible sections
 * (Summary / Monitoring / Orchestration / Inheritance) with proper tables instead
 * of a raw JSON blob. Every section header toggles open/closed, plus a global
 * "collapse all" / "expand all" — mirrors the Windows RSoP HTML report the user
 * referenced.
 */
@Component({
  selector: 'app-desired-state-report',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="bm-gpr">
      <div class="bm-gpr-top">
        <span class="bm-gpr-title">Resultant desired state</span>
        <button type="button" class="bm-gpr-all" (click)="toggleAll()">{{ allCollapsed() ? 'expand all' : 'collapse all' }}</button>
      </div>

      <!-- Summary -->
      <section class="bm-gpr-sec">
        <button type="button" class="bm-gpr-h bm-gpr-h1" (click)="toggle('summary')">
          <span class="bm-gpr-caret">{{ open('summary') ? '▾' : '▸' }}</span> Summary
        </button>
        @if (open('summary')) {
          <table class="bm-gpr-kv">
            <tr><th>Host</th><td>{{ state().state.host.name }}</td></tr>
            <tr><th>Organizational unit</th><td>{{ state().state.host.ou ?? '(unassigned)' }}</td></tr>
            <tr><th>Generation</th><td>{{ state().generation }}</td></tr>
            <tr><th>Config hash</th><td class="bm-gpr-mono">{{ state().config_hash }}</td></tr>
            @if (ouPath().length) {
              <tr><th>Inheritance path</th><td>{{ ouPath().join('  ›  ') }}</td></tr>
            }
          </table>
        }
      </section>

      <!-- Monitoring -->
      <section class="bm-gpr-sec">
        <button type="button" class="bm-gpr-h bm-gpr-h1" (click)="toggle('monitoring')">
          <span class="bm-gpr-caret">{{ open('monitoring') ? '▾' : '▸' }}</span> Monitoring
        </button>
        @if (open('monitoring')) {
          <div class="bm-gpr-sub">
            <h4>Applied checks</h4>
            @if (state().state.monitoring.checks.length) {
              <ul class="bm-gpr-list">@for (c of state().state.monitoring.checks; track c) { <li>{{ c }}</li> }</ul>
            } @else { <p class="bm-gpr-empty">No checks apply.</p> }
          </div>
          <div class="bm-gpr-sub">
            <h4>Thresholds</h4>
            @if (thresholdRows().length) {
              <table class="bm-gpr-tbl">
                <thead><tr><th>Service</th><th>Metric</th><th>Warn</th><th>Crit</th><th>Cmp</th><th>Source</th></tr></thead>
                <tbody>
                  @for (t of thresholdRows(); track t.metric) {
                    <tr>
                      <td>{{ t.service_name ?? '—' }}</td>
                      <td class="bm-gpr-dim">{{ t.metric }}</td>
                      <td>{{ t.warn ?? '—' }}</td>
                      <td>{{ t.crit ?? '—' }}</td>
                      <td class="bm-gpr-dim">{{ t.comparison ?? '' }}</td>
                      <td><span class="bm-gpr-src">{{ t.source ?? '—' }}</span></td>
                    </tr>
                  }
                </tbody>
              </table>
            } @else { <p class="bm-gpr-empty">No thresholds apply.</p> }
          </div>
          <div class="bm-gpr-sub">
            <h4>Notifications</h4>
            @if (state().state.monitoring.notifications.length) {
              <ul class="bm-gpr-list">@for (n of state().state.monitoring.notifications; track n) { <li>{{ n }}</li> }</ul>
            } @else { <p class="bm-gpr-empty">No notification policies apply.</p> }
          </div>
        }
      </section>

      <!-- Orchestration -->
      <section class="bm-gpr-sec">
        <button type="button" class="bm-gpr-h bm-gpr-h1" (click)="toggle('orchestration')">
          <span class="bm-gpr-caret">{{ open('orchestration') ? '▾' : '▸' }}</span> Orchestration
        </button>
        @if (open('orchestration')) {
          <div class="bm-gpr-sub">
            <h4>Roles</h4>
            @if (state().state.orchestration.roles.length) {
              <ul class="bm-gpr-list">@for (r of state().state.orchestration.roles; track r) { <li>{{ r }}</li> }</ul>
            } @else { <p class="bm-gpr-empty">No orchestration roles.</p> }
          </div>
          <div class="bm-gpr-sub">
            <h4>Applied policies</h4>
            @if (planRows().length) {
              <table class="bm-gpr-tbl">
                <thead><tr><th>Policy</th><th>Type</th><th>Ver</th><th>Origin</th><th>Parameters</th></tr></thead>
                <tbody>
                  @for (p of planRows(); track p.name + p.source) {
                    <tr>
                      <td>{{ p.name }}</td>
                      <td class="bm-gpr-dim">{{ p.type }}</td>
                      <td class="bm-gpr-dim">{{ p.version ?? '—' }}</td>
                      <td><span class="bm-gpr-src">{{ p.source }}</span></td>
                      <td class="bm-gpr-params">{{ paramSummary(p.parameters) }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            } @else { <p class="bm-gpr-empty">No policies apply to this host.</p> }
          </div>
        }
      </section>
    </div>
  `,
  styles: [`
    .bm-gpr { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; }
    .bm-gpr-top { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 8px 14px; background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
    .bm-gpr-title { font-weight: 700; }
    .bm-gpr-all { background: none; border: none; color: var(--mat-sys-primary); cursor: pointer; font-size: 13px; }
    .bm-gpr-all:hover { text-decoration: underline; }
    .bm-gpr-sec { border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-gpr-h { width: 100%; text-align: left; border: none; cursor: pointer; font-weight: 600; padding: 8px 14px; display: flex; align-items: center; gap: 8px; color: inherit; }
    .bm-gpr-h1 { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-gpr-h:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-gpr-caret { width: 12px; opacity: 0.7; }
    .bm-gpr-sub { padding: 4px 14px 12px 30px; }
    .bm-gpr-sub h4 { margin: 12px 0 6px; font-size: 13px; opacity: 0.8; }
    .bm-gpr-kv { border-collapse: collapse; margin: 8px 14px 14px 30px; }
    .bm-gpr-kv th { text-align: left; padding: 4px 24px 4px 0; font-weight: 500; opacity: 0.7; vertical-align: top; white-space: nowrap; }
    .bm-gpr-kv td { padding: 4px 0; }
    .bm-gpr-mono, .bm-gpr-params { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
    .bm-gpr-tbl { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-gpr-tbl th { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); font-weight: 600; opacity: 0.8; }
    .bm-gpr-tbl td { padding: 6px 10px; border-bottom: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 50%, transparent); vertical-align: top; }
    .bm-gpr-dim { opacity: 0.65; }
    .bm-gpr-src { font-size: 12px; padding: 1px 8px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-primary) 15%, transparent); white-space: nowrap; }
    .bm-gpr-list { margin: 4px 0; padding-left: 20px; }
    .bm-gpr-list li { padding: 2px 0; }
    .bm-gpr-empty { opacity: 0.6; font-style: italic; margin: 4px 0; }
    .bm-gpr-params { color: var(--mat-sys-on-surface); opacity: 0.8; max-width: 380px; overflow-wrap: anywhere; }
  `],
})
export class DesiredStateReportComponent {
  state = input.required<CompiledHostState>();
  private collapsed = signal<Set<string>>(new Set());

  open(key: string): boolean {
    return !this.collapsed().has(key);
  }
  toggle(key: string): void {
    const s = new Set(this.collapsed());
    s.has(key) ? s.delete(key) : s.add(key);
    this.collapsed.set(s);
  }
  private readonly sections = ['summary', 'monitoring', 'orchestration'];
  allCollapsed = computed(() => this.sections.every((s) => this.collapsed().has(s)));
  toggleAll(): void {
    this.collapsed.set(this.allCollapsed() ? new Set() : new Set(this.sections));
  }

  ouPath = computed<string[]>(() => {
    const explain = (this.state().explain ?? {}) as { ou_path?: string[] };
    return explain.ou_path ?? [];
  });

  thresholdRows = computed<ThresholdRow[]>(() => {
    const t = (this.state().state.monitoring.thresholds ?? {}) as Record<string, Omit<ThresholdRow, 'metric'>>;
    return Object.entries(t).map(([metric, v]) => ({ metric, ...v }));
  });

  planRows = computed<PlanRow[]>(() => {
    const d = this.state();
    const explain = (d.explain ?? {}) as { assignments?: { plan: string; source: string }[] };
    const sourceByPlan = new Map((explain.assignments ?? []).map((a) => [a.plan, a.source] as const));
    return d.state.orchestration.plans.map((p) => ({
      name: p.name,
      version: p.version,
      type: p.type,
      source: sourceByPlan.get(p.name) ?? 'ou',
      parameters: p.parameters ?? {},
    }));
  });

  paramSummary(params: Record<string, unknown>): string {
    const keys = Object.keys(params ?? {});
    if (!keys.length) return '—';
    return keys.map((k) => `${k}=${typeof params[k] === 'object' ? JSON.stringify(params[k]) : params[k]}`).join(', ');
  }
}
