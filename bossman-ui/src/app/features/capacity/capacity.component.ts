import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { ForecastService, CapacityRow } from '../../core/services/forecast.service';

/** Capacity planning / trending (gap #3): projects each host's metric (disk by
 * default) forward with a least-squares trend and shows "full in N days",
 * sorted soonest-first. On-demand, no stored state. */
@Component({
  selector: 'app-capacity',
  standalone: true,
  imports: [DatePipe, FormsModule, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-page">
      <div class="bm-head">
        <div>
          <h1>Capacity forecast</h1>
          <p class="bm-dim">Least-squares trend over each host's recent history projects when a metric will cross the threshold — "disk full in N days". Flat or shrinking series show no ETA.</p>
        </div>
      </div>

      <div class="bm-filters">
        <label>Metric
          <select [(ngModel)]="metric" (ngModelChange)="reload()">
            <option value="disk_used_pct">Disk used %</option>
            <option value="mem_used_pct">Memory used %</option>
            <option value="swap_used_pct">Swap used %</option>
          </select>
        </label>
        <label>Threshold %<input type="number" [(ngModel)]="threshold" (change)="reload()" /></label>
        <label>Lookback (days)<input type="number" [(ngModel)]="lookback" (change)="reload()" /></label>
        <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Recompute</button>
      </div>

      @if (summary(); as s) {
        <div class="bm-summary">
          <span class="bm-pill bm-pill--total">{{ rows().length }} filesystems</span>
          @if (s.critical) { <span class="bm-pill bm-pill--critical">{{ s.critical }} critical</span> }
          @if (s.warning) { <span class="bm-pill bm-pill--warning">{{ s.warning }} warning</span> }
          <span class="bm-pill">{{ s.trending }} trending up</span>
        </div>
      }

      <div class="bm-table-wrap">
        <table class="bm-table">
          <thead><tr><th>Status</th><th>Host</th><th>Filesystem</th><th>Current</th><th>Growth/day</th><th>Full in</th><th>Projected date</th></tr></thead>
          <tbody>
            @for (r of rows(); track r.agent_id + r.label) {
              <tr>
                <td><span class="bm-st bm-st--{{ r.status }}">{{ r.status }}</span></td>
                <td><strong>{{ r.host }}</strong></td>
                <td class="bm-mono">{{ r.label || '—' }}</td>
                <td>
                  <div class="bm-bar"><div class="bm-bar-fill bm-bar-fill--{{ r.status }}" [style.width.%]="r.current"></div></div>
                  <span class="bm-cur">{{ r.current }}%</span>
                </td>
                <td [class.bm-dim]="r.slope_per_day <= 0">{{ r.slope_per_day > 0 ? '+' : '' }}{{ r.slope_per_day }}%</td>
                <td [class.bm-crit]="r.status==='critical'" [class.bm-warn]="r.status==='warning'">
                  {{ r.days_to_threshold === null ? '—' : (r.days_to_threshold + ' days') }}
                </td>
                <td class="bm-dim">{{ r.eta ? (r.eta | date:'yyyy-MM-dd') : '—' }}</td>
              </tr>
            } @empty { <tr><td colspan="7" class="bm-dim">No data — hosts need at least two samples in the lookback window.</td></tr> }
          </tbody>
        </table>
      </div>
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1150px; margin: 0 auto; }
    .bm-head h1 { margin: 0; }
    .bm-dim { opacity: 0.6; }
    .bm-filters { display: flex; gap: 14px; align-items: flex-end; flex-wrap: wrap; margin: 14px 0; }
    .bm-filters label { display: flex; flex-direction: column; font-size: 12px; gap: 4px; }
    .bm-filters input, .bm-filters select { padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; }
    .bm-filters input { width: 110px; }
    .bm-summary { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 14px; }
    .bm-pill { font-size: 12px; padding: 3px 12px; border-radius: 12px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-pill--total { font-weight: 600; }
    .bm-pill--critical { background: color-mix(in srgb, var(--bm-red, #c62828) 22%, transparent); }
    .bm-pill--warning { background: color-mix(in srgb, #f9a825 32%, transparent); }
    .bm-table-wrap { overflow-x: auto; }
    .bm-table { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-table th { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); font-size: 11px; text-transform: uppercase; opacity: 0.6; }
    .bm-table td { padding: 8px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); vertical-align: middle; }
    .bm-mono { font-family: ui-monospace, monospace; }
    .bm-bar { display: inline-block; width: 90px; height: 7px; border-radius: 4px; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); vertical-align: middle; overflow: hidden; margin-right: 7px; }
    .bm-bar-fill { height: 100%; background: var(--bm-green, #2e7d32); }
    .bm-bar-fill--warning { background: #f9a825; } .bm-bar-fill--critical { background: var(--bm-red, #c62828); }
    .bm-cur { font-variant-numeric: tabular-nums; }
    .bm-crit { color: var(--bm-red, #c62828); font-weight: 600; } .bm-warn { color: #f9a825; font-weight: 600; }
    .bm-st { font-size: 11px; padding: 2px 9px; border-radius: 10px; background: color-mix(in srgb, var(--bm-green, #2e7d32) 22%, transparent); }
    .bm-st--warning { background: color-mix(in srgb, #f9a825 34%, transparent); }
    .bm-st--critical { background: color-mix(in srgb, var(--bm-red, #c62828) 26%, transparent); }
  `],
})
export class CapacityComponent implements OnInit {
  private svc = inject(ForecastService);
  rows = signal<CapacityRow[]>([]);
  metric = 'disk_used_pct';
  threshold = 90;
  lookback = 30;
  summary = computed(() => {
    const r = this.rows();
    return {
      critical: r.filter((x) => x.status === 'critical').length,
      warning: r.filter((x) => x.status === 'warning').length,
      trending: r.filter((x) => x.days_to_threshold !== null).length,
    };
  });

  ngOnInit(): void { this.reload(); }
  reload(): void {
    this.svc.capacity({ metric: this.metric, threshold: this.threshold, lookback_days: this.lookback })
      .subscribe((r) => this.rows.set(r));
  }
}
