import { Component, computed, inject, input, signal } from '@angular/core';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService, ServiceAction } from '../../../core/services/agent.service';
import { ServiceUnit } from '../../../core/models/agent.model';

/** Block J4a — the "erweiterte Dienste" section of the Cockpit-like host
 * management page. Lists every systemd service unit (via the read-only
 * `service_facts` module) and offers per-unit start/stop/restart +
 * enable/disable through the agent's write-gated `systemd` module. A
 * read-only agent (write=false) surfaces the agent's 403 as an inline error.
 */
@Component({
  selector: 'app-host-services',
  standalone: true,
  imports: [MatCardModule, MatButtonModule, MatIconModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-mgmt-section">
      <div class="bm-mgmt-toolbar">
        <input
          class="bm-mgmt-filter"
          type="text"
          placeholder="Filter units by name or state…"
          [value]="filter()"
          (input)="filter.set($any($event.target).value)"
        />
        <button mat-stroked-button (click)="reload()" [disabled]="loading()">Reload</button>
        <span class="bm-mgmt-count">{{ filtered().length }} / {{ units().length }} units</span>
        @if (msg()) { <span class="bm-svc-ok">{{ msg() }}</span> }
        @if (err()) { <span class="bm-svc-err">{{ err() }}</span> }
      </div>

      @if (loading()) {
        <div class="bm-mgmt-loading"><mat-spinner diameter="28" /></div>
      } @else if (loadErr()) {
        <p class="bm-svc-err">{{ loadErr() }}</p>
      } @else {
        <table class="bm-mgmt-table">
          <thead>
            <tr>
              <th>Unit</th><th>Load</th><th>Active</th><th>Sub</th><th class="bm-mgmt-actions">Actions</th>
            </tr>
          </thead>
          <tbody>
            @for (u of filtered(); track u.unit) {
              <tr>
                <td class="bm-mgmt-unit">{{ u.name }}</td>
                <td>{{ u.load }}</td>
                <td [class.bm-active]="u.active === 'active'" [class.bm-failed]="u.active === 'failed'">{{ u.active }}</td>
                <td>{{ u.sub }}</td>
                <td class="bm-mgmt-actions">
                  <button mat-button (click)="act(u, 'start')" [disabled]="busy() === u.unit">Start</button>
                  <button mat-button (click)="act(u, 'stop')" [disabled]="busy() === u.unit">Stop</button>
                  <button mat-button (click)="act(u, 'restart')" [disabled]="busy() === u.unit">Restart</button>
                  <button mat-button (click)="act(u, 'enable')" [disabled]="busy() === u.unit">Enable</button>
                  <button mat-button (click)="act(u, 'disable')" [disabled]="busy() === u.unit">Disable</button>
                </td>
              </tr>
            }
          </tbody>
        </table>
      }
    </div>
  `,
  styles: [
    `
      .bm-mgmt-section { padding: 8px 0; }
      .bm-mgmt-toolbar { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; flex-wrap: wrap; }
      .bm-mgmt-filter { flex: 1 1 260px; padding: 6px 10px; border: 1px solid var(--bm-border, #ccc); border-radius: 4px; }
      .bm-mgmt-count { color: var(--bm-muted, #888); font-size: 12px; }
      .bm-mgmt-loading { display: flex; justify-content: center; padding: 24px; }
      .bm-mgmt-table { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-mgmt-table th, .bm-mgmt-table td { text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--bm-border, #eee); }
      .bm-mgmt-unit { font-family: monospace; }
      .bm-mgmt-actions { white-space: nowrap; }
      .bm-active { color: #2e7d32; }
      .bm-failed { color: #c62828; font-weight: 600; }
      .bm-svc-ok { color: #2e7d32; font-size: 12px; }
      .bm-svc-err { color: #c62828; font-size: 12px; }
    `,
  ],
})
export class HostServicesComponent {
  private agentService = inject(AgentService);

  agentId = input.required<string>();

  units = signal<ServiceUnit[]>([]);
  filter = signal('');
  loading = signal(false);
  loaded = signal(false);
  loadErr = signal<string | null>(null);
  busy = signal<string | null>(null);
  msg = signal<string | null>(null);
  err = signal<string | null>(null);

  filtered = computed(() => {
    const f = this.filter().trim().toLowerCase();
    const list = this.units();
    if (!f) return list;
    return list.filter((u) => u.name.toLowerCase().includes(f) || u.active.includes(f) || u.sub.includes(f));
  });

  /** Called by the parent when the Services tab is first opened. */
  loadOnce(): void {
    if (this.loaded() || this.loading()) return;
    this.reload();
  }

  reload(): void {
    this.loading.set(true);
    this.loadErr.set(null);
    this.agentService.services(this.agentId()).subscribe({
      next: (res) => {
        this.units.set(res.services ?? []);
        this.loading.set(false);
        this.loaded.set(true);
      },
      error: (e) => {
        this.loading.set(false);
        this.loaded.set(true);
        this.loadErr.set(e?.error?.detail ?? 'failed to load services');
      },
    });
  }

  act(u: ServiceUnit, action: ServiceAction): void {
    if (this.busy()) return;
    this.busy.set(u.unit);
    this.msg.set(null);
    this.err.set(null);
    this.agentService.serviceControl(this.agentId(), u.name, action).subscribe({
      next: (res) => {
        this.busy.set(null);
        const r = res.result as { changed?: boolean; msg?: string } | undefined;
        this.msg.set(`${action} ${u.name}: ${r?.msg ?? 'ok'}${r?.changed === false ? ' (no change)' : ''}`);
        // Refresh state after a running-state change so the table reflects reality.
        if (action !== 'enable' && action !== 'disable') this.reload();
      },
      error: (e) => {
        this.busy.set(null);
        this.err.set(e?.error?.detail ?? `${action} failed`);
      },
    });
  }
}
