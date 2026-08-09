import { Component, computed, input } from '@angular/core';

/** CheckMK's own "Perf-O-Meter" — a compact inline bar showing one metric
 * value at a glance, threshold-colored (see docs/plan.md's monitoring-
 * cockpit ergänzung Block F3). Deliberately tiny and reusable: the host-
 * overview table uses one per column (CPU/RAM/Disk), not a full chart —
 * the full history graph is one click away in host detail. */
@Component({
  selector: 'app-perf-o-meter',
  standalone: true,
  template: `
    <div class="bm-pom" [title]="tooltip()">
      <div class="bm-pom-track">
        <div class="bm-pom-fill" [class]="'bm-pom-fill--' + severity()" [style.width.%]="pct()"></div>
      </div>
      <span class="bm-pom-label">{{ displayLabel() }}</span>
    </div>
  `,
  styles: [
    `
      .bm-pom {
        display: flex;
        align-items: center;
        gap: 8px;
        min-width: 120px;
      }
      .bm-pom-track {
        position: relative;
        flex: 1;
        height: 8px;
        border-radius: 4px;
        background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent);
        overflow: hidden;
      }
      .bm-pom-fill {
        position: absolute;
        inset: 0;
        width: 0;
        border-radius: 4px;
        transition: width 0.2s ease;
      }
      .bm-pom-fill--ok {
        background: var(--bm-green);
      }
      .bm-pom-fill--warn {
        background: var(--bm-gold);
      }
      .bm-pom-fill--crit {
        background: var(--bm-red);
      }
      .bm-pom-fill--unknown {
        background: var(--bm-unknown);
      }
      .bm-pom-label {
        font-size: 12px;
        font-variant-numeric: tabular-nums;
        opacity: 0.85;
        white-space: nowrap;
        min-width: 40px;
        text-align: right;
      }
    `,
  ],
})
export class PerfOMeterComponent {
  /** null = no data yet (rendered as an empty, grey bar with "—"). */
  value = input<number | null>(null);
  max = input<number>(100);
  warn = input<number | null>(null);
  crit = input<number | null>(null);
  unit = input<string>('%');

  pct = computed(() => {
    const v = this.value();
    if (v === null) return 0;
    return Math.max(0, Math.min(100, (v / this.max()) * 100));
  });

  severity = computed((): 'ok' | 'warn' | 'crit' | 'unknown' => {
    const v = this.value();
    if (v === null) return 'unknown';
    const crit = this.crit();
    const warn = this.warn();
    if (crit !== null && v >= crit) return 'crit';
    if (warn !== null && v >= warn) return 'warn';
    return 'ok';
  });

  displayLabel = computed(() => {
    const v = this.value();
    if (v === null) return '—';
    return `${v.toFixed(1)}${this.unit()}`;
  });

  tooltip = computed(() => {
    const v = this.value();
    return v === null ? 'No data yet' : `${v.toFixed(2)}${this.unit()}`;
  });
}
