import { Component, inject, signal } from '@angular/core';
import { DecimalPipe } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { HostManagementComponent } from '../features/hosts/management/host-management.component';
import { StandaloneLoginComponent } from './standalone-login.component';
import { StandaloneOverviewComponent } from './standalone-overview.component';
import { authToken, clearAuth } from './agent-auth';

interface Proc { pid: number; user: string; comm: string; command: string; cpu_percent: number; rss_kib: number; state: string; }

/**
 * The standalone-agent console shell: served by the agent at /ui, talking to
 * its own API. Gated by PAM login. Reuses the real fleet **Management** console
 * (all snap-ins) against this single host, plus a **Processes** view. Custom
 * checks / service checks are intentionally excluded (fleet-monitoring
 * concerns). Inventory is added next.
 */
@Component({
  selector: 'app-root',
  standalone: true,
  imports: [HostManagementComponent, StandaloneLoginComponent, StandaloneOverviewComponent, DecimalPipe],
  template: `
    @if (!authed()) {
      <app-standalone-login />
    } @else {
      <div class="bm-shell">
        <header class="bm-top">
          <img class="bm-logo" src="assets/yolo-man.jpg" alt="YOLO-MAN" />
          <strong>YOLO-MANager</strong><span class="bm-dim">standalone agent</span>
          <nav>
            <button [class.on]="tab()==='overview'" (click)="tab.set('overview')">Overview</button>
            <button [class.on]="tab()==='management'" (click)="tab.set('management')">Management</button>
            <button [class.on]="tab()==='processes'" (click)="select('processes')">Processes</button>
          </nav>
          <span class="bm-spacer"></span>
          <button class="bm-logout" (click)="logout()">Log out</button>
        </header>
        <main class="bm-main" [class.bm-main-flush]="tab()==='overview'">
          @if (tab()==='overview') { <app-standalone-overview /> }
          <div [style.display]="tab()==='management' ? 'block' : 'none'">
            <!-- Nothing to hide any more: 'servicechecks' was the one Fleet-Commander
                 snap-in here, and service checks now live on the host's Checks tab, which
                 this standalone console does not have at all. -->
            <app-host-management [agentId]="agentId" />
          </div>
          @if (tab()==='processes') {
            <div class="bm-proc">
              <div class="bm-proc-head"><h3>Processes ({{ procs().length }})</h3><button (click)="loadProcs()" [disabled]="procBusy()">↻ Refresh</button></div>
              <table class="bm-t">
                <thead><tr><th>PID</th><th>User</th><th>CPU%</th><th>RSS (MiB)</th><th>State</th><th>Command</th></tr></thead>
                <tbody>
                  @for (p of procs(); track p.pid) {
                    <tr><td>{{ p.pid }}</td><td>{{ p.user }}</td><td>{{ p.cpu_percent | number:'1.0-1' }}</td><td>{{ (p.rss_kib/1024) | number:'1.0-0' }}</td><td>{{ p.state }}</td><td class="bm-cmd">{{ p.command }}</td></tr>
                  }
                </tbody>
              </table>
            </div>
          }
        </main>
      </div>
    }
  `,
  styles: [`
    .bm-shell { display: flex; flex-direction: column; height: 100vh; font-family: system-ui, sans-serif; }
    .bm-top { display: flex; align-items: center; gap: 10px; padding: 8px 14px; background: #1b1b1b; color: #eee; }
    .bm-top .bm-logo { height: 30px; width: auto; border-radius: 5px; display: block; }
    .bm-top .bm-dim { opacity: 0.55; font-size: 12px; }
    .bm-top nav { display: flex; gap: 4px; margin-left: 14px; }
    .bm-top nav button { padding: 4px 14px; background: transparent; color: #ccc; border: 1px solid #444; border-radius: 4px; cursor: pointer; }
    .bm-top nav button.on { background: #2e7d32; color: #fff; border-color: #2e7d32; }
    .bm-spacer { flex: 1; }
    .bm-logout { padding: 4px 12px; background: transparent; color: #ccc; border: 1px solid #444; border-radius: 4px; cursor: pointer; }
    .bm-main { flex: 1 1 auto; overflow: auto; background: var(--mat-sys-surface, #fff); color: var(--mat-sys-on-surface, #111); padding: 16px; }
    .bm-main.bm-main-flush { padding: 0; display: flex; }
    .bm-main.bm-main-flush > app-standalone-overview { flex: 1; min-width: 0; }
    .bm-proc-head { display: flex; align-items: center; gap: 12px; }
    .bm-t { width: 100%; border-collapse: collapse; font-size: 13px; margin-top: 10px; }
    .bm-t th { text-align: left; opacity: 0.7; padding: 4px 8px; } .bm-t td { padding: 3px 8px; border-top: 1px solid #8883; }
    .bm-cmd { font-family: ui-monospace, monospace; font-size: 12px; }
  `],
})
export class StandaloneShellComponent {
  private http = inject(HttpClient);
  readonly agentId = 'self';
  constructor() { document.title = 'YOLO-MANager'; }
  tab = signal<'overview' | 'management' | 'processes'>('overview');
  authed = () => !!authToken();
  procs = signal<Proc[]>([]);
  procBusy = signal(false);

  select(t: 'processes'): void { this.tab.set(t); if (!this.procs().length) this.loadProcs(); }

  loadProcs(): void {
    this.procBusy.set(true);
    this.http.get<{ processes: Proc[] }>('/api/v1/processes').subscribe({
      next: (r) => { this.procBusy.set(false); this.procs.set(r.processes || []); },
      error: () => this.procBusy.set(false),
    });
  }

  logout(): void { clearAuth(); }
}
