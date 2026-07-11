import { Component, computed, input } from '@angular/core';

/** Cockpit's StorageUsageBar (../cockpit/pkg/storaged/storage-controls.jsx):
 * a "X used / Y total" label above a two-layer bar; turns red past a critical
 * fraction. Reusable for filesystem/VG usage anywhere in the UI. */
@Component({
  selector: 'app-usage-bar',
  standalone: true,
  template: `
    <div class="ub" [class.ub-short]="short()">
      @if (!short()) {
        <div class="ub-label">{{ label() }}</div>
      }
      <div class="ub-track" [title]="label()">
        <div class="ub-fill" [class.ub-danger]="danger()" [style.width.%]="pct()"></div>
      </div>
    </div>
  `,
  styles: [
    `
      .ub { display: flex; flex-direction: column; gap: 3px; min-width: 120px; }
      .ub-short { min-width: 80px; }
      .ub-label { font-size: 11.5px; opacity: 0.7; font-variant-numeric: tabular-nums; }
      .ub-track { height: 8px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); overflow: hidden; }
      .ub-fill { height: 100%; background: var(--mat-sys-primary); border-radius: 999px; transition: width 0.2s; }
      .ub-fill.ub-danger { background: #c62828; }
    `,
  ],
})
export class UsageBarComponent {
  /** Used bytes. */
  used = input<number>(0);
  /** Total bytes. */
  total = input<number>(0);
  /** Fraction (0..1) above which the bar turns red. */
  critical = input<number>(0.9);
  /** Compact variant for table cells (hides the text label). */
  short = input<boolean>(false);

  pct = computed(() => {
    const t = this.total();
    if (!t) return 0;
    return Math.min(100, (this.used() / t) * 100);
  });

  danger = computed(() => {
    const t = this.total();
    return !!t && this.used() / t >= this.critical();
  });

  label = computed(() => `${fmtBytes(this.used())} / ${fmtBytes(this.total())}`);
}

/** Human byte size (binary units), matching Cockpit's fsys usage strings. */
export function fmtBytes(n: number): string {
  if (!n || n < 0) return '0 B';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}
