import { Component, effect, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MonitoringService } from '../../core/services/monitoring.service';
import { EffectiveThreshold } from '../../core/models/monitoring.model';

/**
 * "Effective parameters" (Block E) — Checkmk has a page that shows which rule
 * governs a service and why; we show the same, but with OUR precedence, which
 * is the REVERSE of Checkmk's top-first: the closest-to-host rule wins
 * (host > site > OU-deep > group > global) unless a higher rule is `enforced`
 * or an OU on the path blocks inheritance.
 *
 * For each metric (per label series) it lists every rule that applies to this
 * host, ranked most-authoritative first: the WINNER (green, with its thresholds)
 * and the losers, each with a one-line reason it lost. This is exactly what the
 * poller acts on — the same resolver, exposed as an explanation.
 */
@Component({
  selector: 'app-effective-thresholds',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="bm-eff">
      <div class="bm-eff-head">
        <span class="bm-dim">
          Which threshold rule governs each service on this host — and why. The
          <strong>closest-to-host</strong> rule wins (host &rsaquo; site &rsaquo; OU &rsaquo; group &rsaquo; global),
          unless a higher rule is <em>enforced</em> or an OU blocks inheritance.
        </span>
        <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Reload</button>
      </div>

      @if (loading()) {
        <p class="bm-dim">Resolving effective rules…</p>
      } @else if (err()) {
        <p class="bm-err">{{ err() }}</p>
      } @else if (rows().length === 0) {
        <p class="bm-dim">No threshold rules apply to this host yet.</p>
      } @else {
        @for (r of rows(); track r.metric + (r.label_value ?? '')) {
          <div class="bm-eff-metric">
            <div class="bm-eff-title">
              <span class="bm-eff-name">{{ r.display_name }}</span>
              @if (r.label_value) { <span class="bm-eff-label">{{ r.label_value }}</span> }
              <span class="bm-eff-svc">{{ r.service_name }}</span>
              <code class="bm-eff-key">{{ r.metric }}</code>
            </div>
            <div class="bm-eff-cands">
              @for (c of r.candidates; track c.rule_id) {
                <div class="bm-eff-cand" [class.win]="c.is_winner">
                  <mat-icon class="bm-eff-ic">{{ c.is_winner ? 'check_circle' : 'radio_button_unchecked' }}</mat-icon>
                  <span class="bm-eff-scope">{{ c.scope_label }}</span>
                  @if (c.enforced) { <span class="bm-eff-enf">enforced</span> }
                  <span class="bm-eff-thr">{{ thresholds(c) }}</span>
                  <span class="bm-eff-reason">{{ c.reason }}</span>
                </div>
              }
            </div>
          </div>
        }
      }
    </div>
  `,
  styles: [
    `
      .bm-eff { padding: 4px 0; }
      .bm-eff-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; margin-bottom: 14px; }
      .bm-eff-head .bm-dim { max-width: 720px; line-height: 1.5; }
      .bm-dim { opacity: 0.7; font-size: 13px; }
      .bm-err { color: var(--bm-red); font-size: 13px; }
      .bm-eff-metric { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; margin-bottom: 10px; overflow: hidden; }
      .bm-eff-title { display: flex; align-items: baseline; gap: 10px; padding: 8px 12px; background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
      .bm-eff-name { font-weight: 600; font-size: 13.5px; }
      .bm-eff-label { font-size: 11.5px; padding: 1px 6px; border-radius: 4px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
      .bm-eff-svc { font-size: 12px; opacity: 0.7; }
      .bm-eff-key { margin-left: auto; font-family: ui-monospace, monospace; font-size: 11.5px; opacity: 0.55; }
      .bm-eff-cands { padding: 2px 0; }
      .bm-eff-cand { display: flex; align-items: center; gap: 10px; padding: 5px 12px; font-size: 13px; opacity: 0.72; }
      .bm-eff-cand.win { opacity: 1; background: color-mix(in srgb, var(--mat-sys-primary) 8%, transparent); }
      .bm-eff-ic { font-size: 16px; width: 16px; height: 16px; opacity: 0.55; }
      .bm-eff-cand.win .bm-eff-ic { color: var(--bm-green); opacity: 1; }
      .bm-eff-scope { min-width: 200px; }
      .bm-eff-enf { font-size: 10.5px; font-weight: 700; letter-spacing: 0.04em; text-transform: uppercase; color: var(--bm-gold); }
      .bm-eff-thr { font-family: ui-monospace, monospace; font-size: 12px; opacity: 0.85; }
      .bm-eff-reason { margin-left: auto; font-size: 11.5px; opacity: 0.6; font-style: italic; }
    `,
  ],
})
export class EffectiveThresholdsComponent {
  private monitoring = inject(MonitoringService);
  agentId = input.required<string>();

  rows = signal<EffectiveThreshold[]>([]);
  loading = signal(false);
  err = signal<string | null>(null);

  constructor() {
    // Reload whenever the bound agent changes (input is a signal).
    effect(() => {
      const id = this.agentId();
      if (id) this.load(id);
    });
  }

  reload(): void {
    const id = this.agentId();
    if (id) this.load(id);
  }

  private load(id: string): void {
    this.loading.set(true);
    this.err.set(null);
    this.monitoring.effectiveThresholds(id).subscribe({
      next: (r) => {
        this.rows.set(r);
        this.loading.set(false);
      },
      error: (e: { error?: { detail?: string } }) => {
        this.err.set(e?.error?.detail ?? 'failed to resolve effective rules');
        this.loading.set(false);
      },
    });
  }

  /** Human threshold summary for one candidate (state checks carry none). */
  thresholds(c: EffectiveThreshold['candidates'][number]): string {
    if (c.warn_threshold == null && c.crit_threshold == null) return 'state check';
    const op = { gt: '>', lt: '<', ge: '≥', le: '≤', eq: '=', ne: '≠' }[c.comparison ?? 'gt'] ?? c.comparison;
    const parts: string[] = [];
    if (c.warn_threshold != null) parts.push(`warn ${op} ${c.warn_threshold}`);
    if (c.crit_threshold != null) parts.push(`crit ${op} ${c.crit_threshold}`);
    return parts.join(', ');
  }
}
