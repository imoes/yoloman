import { Component, OnInit, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { ConfigSyncService, SyncStatus } from '../../core/services/config-sync.service';

/** Config distribution (gap #15): visibility + on-demand trigger for the
 * convergence sweep that keeps every agent's pushed config up to date. The
 * sweep also runs automatically on an interval. */
@Component({
  selector: 'app-config-sync',
  standalone: true,
  imports: [DatePipe, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-page">
      <h1>Config distribution</h1>
      <p class="bm-dim">Config changes (thresholds, checks, OU/group policies, roles) are pushed to agents automatically by the reconciler. This convergence sweep is the backstop: it re-pushes to any host whose compiled config is ahead of what it last acknowledged — hosts that were offline, freshly enrolled, or missed an event.</p>

      @if (status(); as s) {
        <div class="bm-grid">
          <div class="bm-stat" [class.bm-stat--bad]="s.hosts_behind > 0">
            <div class="bm-num">{{ s.hosts_behind }}</div><div class="bm-lbl">hosts behind</div>
          </div>
          <div class="bm-stat"><div class="bm-num">{{ s.pushed }}</div><div class="bm-lbl">pushed (total)</div></div>
          <div class="bm-stat" [class.bm-stat--bad]="s.failed > 0"><div class="bm-num">{{ s.failed }}</div><div class="bm-lbl">failed (total)</div></div>
          <div class="bm-stat"><div class="bm-num">{{ s.checked }}</div><div class="bm-lbl">checked (total)</div></div>
        </div>

        <div class="bm-card">
          <div class="bm-line"><span class="bm-k">Automatic sweep</span><span class="bm-v">{{ s.enabled ? 'enabled' : 'disabled' }} · every {{ s.interval_seconds }}s</span></div>
          <div class="bm-line"><span class="bm-k">Last sweep</span><span class="bm-v">{{ s.last_run_at ? (s.last_run_at | date:'yyyy-MM-dd HH:mm:ss') : 'not yet run' }}</span></div>
          <div class="bm-actions">
            <button mat-flat-button color="primary" (click)="runNow()" [disabled]="running()">
              <mat-icon>{{ running() ? 'hourglass_empty' : 'sync' }}</mat-icon> {{ running() ? 'Syncing…' : 'Sync now' }}
            </button>
            @if (lastRun(); as r) { <span class="bm-result">Pushed {{ r.pushed }}, {{ r.failed }} failed of {{ r.checked }} checked.</span> }
          </div>
        </div>
      }
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 820px; margin: 0 auto; }
    h1 { margin: 0 0 6px; }
    .bm-dim { opacity: 0.65; font-size: 13px; margin-bottom: 18px; }
    .bm-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin-bottom: 16px; }
    .bm-stat { border: 1px solid var(--mat-sys-outline-variant); border-radius: 12px; padding: 16px; text-align: center;
      background: var(--mat-sys-surface-container-low, rgba(127,127,127,0.04)); }
    .bm-stat--bad { border-color: color-mix(in srgb, var(--bm-red, #c62828) 50%, transparent); background: color-mix(in srgb, var(--bm-red, #c62828) 8%, transparent); }
    .bm-num { font-size: 30px; font-weight: 700; font-variant-numeric: tabular-nums; }
    .bm-lbl { font-size: 12px; opacity: 0.62; margin-top: 4px; }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 12px; padding: 16px 18px;
      background: var(--mat-sys-surface-container-low, rgba(127,127,127,0.04)); }
    .bm-line { display: flex; justify-content: space-between; padding: 6px 0; font-size: 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-k { opacity: 0.7; } .bm-v { font-variant-numeric: tabular-nums; }
    .bm-actions { display: flex; align-items: center; gap: 12px; margin-top: 14px; }
    .bm-result { font-size: 13px; opacity: 0.75; }
  `],
})
export class ConfigSyncComponent implements OnInit {
  private svc = inject(ConfigSyncService);
  status = signal<SyncStatus | null>(null);
  running = signal(false);
  lastRun = signal<{ checked: number; pushed: number; failed: number } | null>(null);

  ngOnInit(): void { this.reload(); }
  reload(): void { this.svc.status().subscribe((s) => this.status.set(s)); }
  runNow(): void {
    this.running.set(true);
    this.svc.run().subscribe({
      next: (r) => { this.running.set(false); this.lastRun.set(r); this.reload(); },
      error: () => this.running.set(false),
    });
  }
}
