import { Component, inject, signal, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { AgentApi, Process, ToolInfo } from './agent-api.service';

/** Standalone host overview straight from the agent's own API: live process
 * table + the tools this agent exposes + its metric catalog. Read-only. */
@Component({
  selector: 'app-host-view',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="hv">
      <div class="hv-head">
        <h2>Host</h2>
        <button (click)="refresh()" [disabled]="loading()">↻ Refresh</button>
        <span class="hv-err" *ngIf="error()">{{ error() }}</span>
      </div>

      <section>
        <h3>Processes <span class="dim" *ngIf="procs().length">({{ procs().length }})</span></h3>
        <table class="grid" *ngIf="procs().length; else noProc">
          <thead><tr><th class="n">PID</th><th>User</th><th class="n">CPU%</th><th class="n">RSS</th><th>Command</th></tr></thead>
          <tbody>
            <tr *ngFor="let p of procs()">
              <td class="n">{{ p.pid }}</td><td>{{ p.user }}</td>
              <td class="n">{{ p.cpu_percent | number: '1.1-1' }}</td>
              <td class="n">{{ (p.rss_kib / 1024) | number: '1.0-0' }} MiB</td>
              <td class="cmd">{{ p.command }}</td>
            </tr>
          </tbody>
        </table>
        <ng-template #noProc><p class="dim">No process data.</p></ng-template>
      </section>

      <section>
        <h3>Tools <span class="dim" *ngIf="tools().length">({{ tools().length }})</span></h3>
        <div class="chips">
          <span class="chip" *ngFor="let t of tools()" [class.w]="t.writes">{{ t.name }}</span>
        </div>
      </section>

      <section>
        <h3>Metrics</h3>
        <div class="chips"><span class="chip" *ngFor="let m of metrics()">{{ m }}</span></div>
      </section>
    </div>
  `,
  styles: [`
    .hv { padding: 12px; }
    .hv-head { display: flex; gap: 10px; align-items: center; }
    .hv-err { color: #f44034; }
    section { margin-top: 16px; }
    .grid { width: 100%; border-collapse: collapse; font-size: 13px; }
    .grid th, .grid td { text-align: left; padding: 3px 8px; border-bottom: 1px solid #eee; }
    .grid .n { text-align: right; font-variant-numeric: tabular-nums; }
    .grid .cmd { font-family: monospace; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 520px; }
    .chips { display: flex; flex-wrap: wrap; gap: 6px; }
    .chip { padding: 2px 8px; border-radius: 10px; background: #eef; font-size: 12px; font-family: monospace; }
    .chip.w { background: #fee; }
    .dim { opacity: 0.6; }
  `],
})
export class HostViewComponent implements OnInit {
  private api = inject(AgentApi);
  procs = signal<Process[]>([]);
  tools = signal<ToolInfo[]>([]);
  metrics = signal<string[]>([]);
  loading = signal(false);
  error = signal<string | null>(null);

  ngOnInit(): void { this.refresh(); }

  refresh(): void {
    this.loading.set(true);
    this.error.set(null);
    this.api.processes(40).subscribe({
      next: (r) => { this.procs.set(r.processes); this.loading.set(false); },
      error: (e) => { this.error.set(e?.error?.error || e.message || 'load failed'); this.loading.set(false); },
    });
    this.api.tools().subscribe({ next: (r) => this.tools.set(r.tools || []), error: () => {} });
    this.api.metricNames().subscribe({ next: (r) => this.metrics.set(r.metrics || []), error: () => {} });
  }
}
