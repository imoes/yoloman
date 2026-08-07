import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { OuService, PolicyReport, PolicyReportRow } from '../../core/services/ou.service';

/**
 * Policy report (Resultant Set of Policy) for an OU / Site / group — the right-
 * hand pane of the OU/Policy page. It answers "which rules actually apply here,
 * and where do they come from?" instead of editing config inline: variables set
 * at this scope (and inherited), plus every config policy, threshold, plan and
 * notification that applies, grouped by kind and labelled with its origin
 * ('here' vs an ancestor OU vs Global). Ordering follows OUR precedence, so the
 * closest-to-host rule is the one that wins.
 */
@Component({
  selector: 'app-policy-report',
  standalone: true,
  imports: [MatIconModule],
  template: `
    @if (loading()) {
      <p class="bm-dim">Resolving what applies here…</p>
    } @else if (err()) {
      <p class="bm-err">{{ err() }}</p>
    } @else if (report(); as r) {
      <p class="bm-rep-lead">What applies to hosts in <strong>{{ r.scope_label }}</strong> — set here or inherited. The
        closest-to-host rule wins.</p>

      <section class="bm-rep-sec">
        <h3>Variables <span class="bm-rep-n">{{ r.variables.length }}</span></h3>
        @if (r.variables.length) {
          <table class="bm-rep-tbl">
            @for (v of r.variables; track v.key + v.origin) {
              <tr>
                <td class="bm-rep-k">{{ v.key }}</td>
                <td class="bm-rep-v">{{ v.value }}</td>
                <td class="bm-rep-o">{{ v.origin }}</td>
              </tr>
            }
          </table>
        } @else {
          <p class="bm-dim">No variables set at or above this scope.</p>
        }
      </section>

      @for (g of groups(); track g.kind) {
        <section class="bm-rep-sec">
          <h3><mat-icon class="bm-rep-ic">{{ icon(g.kind) }}</mat-icon> {{ title(g.kind) }} <span class="bm-rep-n">{{ g.rows.length }}</span></h3>
          <table class="bm-rep-tbl">
            @for (row of g.rows; track row.label + row.origin + row.detail) {
              <tr>
                <td class="bm-rep-k">{{ row.label }}
                  @if (row.enforced) { <span class="bm-rep-enf">enforced</span> }
                </td>
                <td class="bm-rep-v">{{ row.detail }}</td>
                <td class="bm-rep-o" [class.bm-rep-here]="row.origin === 'here'">{{ row.origin }}</td>
              </tr>
            }
          </table>
        </section>
      }

      @if (!r.rows.length && !r.variables.length) {
        <p class="bm-dim">Nothing applies here yet — drag a policy from the palette onto this scope, or right-click to add one.</p>
      }
    }
  `,
  styles: [
    `
      :host { display: block; }
      .bm-dim { opacity: 0.7; font-size: 13px; }
      .bm-err { color: var(--bm-red); font-size: 13px; }
      .bm-rep-lead { font-size: 13px; opacity: 0.8; line-height: 1.5; margin: 0 0 14px; }
      .bm-rep-sec { margin-bottom: 16px; }
      .bm-rep-sec h3 { display: flex; align-items: center; gap: 6px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; opacity: 0.75; margin: 0 0 6px; }
      .bm-rep-ic { font-size: 16px; width: 16px; height: 16px; }
      .bm-rep-n { margin-left: 2px; opacity: 0.6; font-weight: 400; }
      .bm-rep-tbl { width: 100%; border-collapse: collapse; }
      .bm-rep-tbl td { padding: 4px 8px; border-bottom: 1px solid var(--bm-hairline); vertical-align: top; font-size: 13px; }
      .bm-rep-k { font-weight: 600; }
      .bm-rep-v { font-family: ui-monospace, monospace; font-size: 12px; opacity: 0.85; }
      .bm-rep-o { text-align: right; font-size: 11.5px; opacity: 0.6; white-space: nowrap; }
      .bm-rep-here { color: var(--bm-green); opacity: 0.9; }
      .bm-rep-enf { font-size: 10px; font-weight: 700; letter-spacing: 0.04em; text-transform: uppercase; color: var(--bm-gold); margin-left: 6px; }
    `,
  ],
})
export class PolicyReportComponent {
  private ouService = inject(OuService);
  scopeType = input.required<'ou' | 'site' | 'group'>();
  scopeId = input.required<string>();

  report = signal<PolicyReport | null>(null);
  loading = signal(false);
  err = signal<string | null>(null);

  // Rules grouped by kind, in precedence-reading order (config → threshold → plan → notification).
  private static readonly ORDER: PolicyReportRow['kind'][] = ['config', 'threshold', 'plan', 'notification'];
  groups = computed(() => {
    const r = this.report();
    if (!r) return [];
    return PolicyReportComponent.ORDER
      .map((kind) => ({ kind, rows: r.rows.filter((x) => x.kind === kind) }))
      .filter((g) => g.rows.length);
  });

  constructor() {
    effect(() => {
      const t = this.scopeType();
      const id = this.scopeId();
      if (t && id) this.load(t, id);
    });
  }

  private load(scopeType: 'ou' | 'site' | 'group', scopeId: string): void {
    this.loading.set(true);
    this.err.set(null);
    this.ouService.policyReport(scopeType, scopeId).subscribe({
      next: (r) => { this.report.set(r); this.loading.set(false); },
      error: (e: { error?: { detail?: string } }) => { this.err.set(e?.error?.detail ?? 'failed to build report'); this.loading.set(false); },
    });
  }

  icon(kind: string): string {
    return { config: 'dataset', threshold: 'speed', plan: 'widgets', notification: 'notifications' }[kind] ?? 'policy';
  }
  title(kind: string): string {
    return { config: 'Config policies', threshold: 'Thresholds & checks', plan: 'Plans / roles', notification: 'Notifications' }[kind] ?? kind;
  }
}
