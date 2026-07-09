import { Component, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';
import { NetworkResponse } from '../../../core/models/agent.model';

/** Block J4e — the Network section: current interfaces/addresses/routes/DNS
 * (via the baked yoloman.network_interface module, gathered mode) plus a
 * configure form (NetworkManager). Configure defaults to dry-run and fails
 * cleanly on hosts without nmcli. */
@Component({
  selector: 'app-host-network',
  standalone: true,
  imports: [MatButtonModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-mgmt-section">
      <div class="bm-mgmt-toolbar">
        <button mat-stroked-button (click)="reload()" [disabled]="loading()">Reload</button>
        @if (msg()) { <span class="bm-svc-ok">{{ msg() }}</span> }
        @if (err()) { <span class="bm-svc-err">{{ err() }}</span> }
      </div>

      @if (loading()) {
        <div class="bm-mgmt-loading"><mat-spinner diameter="28" /></div>
      } @else if (loadErr()) {
        <p class="bm-svc-err">{{ loadErr() }}</p>
      } @else if (data(); as n) {
        <h4>Interfaces</h4>
        <table class="bm-mgmt-table"><thead><tr><th>Interface</th><th>State</th><th>Addresses</th></tr></thead><tbody>
          @for (i of n.interfaces; track i.name) {
            <tr>
              <td class="bm-mgmt-unit">{{ i.name }}</td>
              <td [class.bm-active]="i.state === 'UP'">{{ i.state }}</td>
              <td>@for (a of i.addresses; track a.cidr) { <span class="bm-addr">{{ a.cidr }}</span> }</td>
            </tr>
          }
        </tbody></table>

        <h4>Routes</h4>
        <table class="bm-mgmt-table"><thead><tr><th>Destination</th><th>Gateway</th><th>Dev</th></tr></thead><tbody>
          @for (r of n.routes; track r.raw) { <tr><td class="bm-mgmt-unit">{{ r.dest }}</td><td>{{ r.gateway || '—' }}</td><td>{{ r.dev || '—' }}</td></tr> }
        </tbody></table>

        <h4>DNS</h4>
        <p class="bm-dns">nameservers: {{ (n.dns.nameservers || []).join(', ') || '—' }}<br />search: {{ (n.dns.search || []).join(', ') || '—' }}</p>

        <h4>Configure interface</h4>
        <div class="bm-net-form">
          <div class="bm-acct-new">
            <input type="text" placeholder="interface (e.g. eth0)" [value]="cfgName()" (input)="cfgName.set($any($event.target).value)" />
            <select [value]="cfgMethod()" (change)="cfgMethod.set($any($event.target).value)">
              <option value="dhcp">dhcp</option>
              <option value="static">static</option>
            </select>
            <label class="bm-chk"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
          </div>
          @if (cfgMethod() === 'static') {
            <div class="bm-acct-new">
              <input type="text" placeholder="address CIDR (10.0.0.5/24)" [value]="cfgAddr()" (input)="cfgAddr.set($any($event.target).value)" />
              <input type="text" placeholder="gateway (optional)" [value]="cfgGw()" (input)="cfgGw.set($any($event.target).value)" />
              <input type="text" placeholder="dns comma-sep (optional)" [value]="cfgDns()" (input)="cfgDns.set($any($event.target).value)" />
            </div>
          }
          <button mat-stroked-button (click)="apply()" [disabled]="busy() || !cfgName().trim()">Apply</button>
        </div>
      }
    </div>
  `,
  styles: [
    `
      .bm-mgmt-section { padding: 8px 0; }
      .bm-mgmt-toolbar { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; flex-wrap: wrap; }
      .bm-mgmt-loading { display: flex; justify-content: center; padding: 24px; }
      h4 { margin: 16px 0 6px; }
      .bm-mgmt-table { width: 100%; border-collapse: collapse; font-size: 13px; margin-bottom: 4px; }
      .bm-mgmt-table th, .bm-mgmt-table td { text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--bm-border, #eee); }
      .bm-mgmt-unit { font-family: monospace; }
      .bm-addr { font-family: monospace; margin-right: 8px; }
      .bm-active { color: #2e7d32; }
      .bm-dns { font-size: 13px; color: var(--bm-fg, inherit); }
      .bm-net-form { margin-top: 6px; }
      .bm-acct-new { display: flex; gap: 8px; margin-bottom: 8px; flex-wrap: wrap; align-items: center; }
      .bm-acct-new input, .bm-acct-new select { padding: 6px 8px; border: 1px solid var(--bm-border, #ccc); border-radius: 4px; }
      .bm-chk { font-size: 12px; color: var(--bm-muted, #888); display: flex; align-items: center; gap: 4px; }
      .bm-svc-ok { color: #2e7d32; font-size: 12px; }
      .bm-svc-err { color: #c62828; font-size: 12px; }
    `,
  ],
})
export class HostNetworkComponent {
  private agentService = inject(AgentService);

  agentId = input.required<string>();

  data = signal<NetworkResponse | null>(null);
  loading = signal(false);
  loaded = signal(false);
  loadErr = signal<string | null>(null);
  busy = signal(false);
  msg = signal<string | null>(null);
  err = signal<string | null>(null);

  cfgName = signal('');
  cfgMethod = signal<'dhcp' | 'static'>('dhcp');
  cfgAddr = signal('');
  cfgGw = signal('');
  cfgDns = signal('');
  dryRun = signal(true);

  loadOnce(): void {
    if (this.loaded() || this.loading()) return;
    this.reload();
  }

  reload(): void {
    this.loading.set(true);
    this.loadErr.set(null);
    this.agentService.network(this.agentId()).subscribe({
      next: (res) => {
        this.data.set(res);
        this.loading.set(false);
        this.loaded.set(true);
      },
      error: (e) => {
        this.loading.set(false);
        this.loaded.set(true);
        this.loadErr.set(e?.error?.detail ?? 'failed to load network');
      },
    });
  }

  apply(): void {
    const name = this.cfgName().trim();
    if (!name) return;
    this.busy.set(true);
    this.msg.set(null);
    this.err.set(null);
    const dns = this.cfgDns().trim() ? this.cfgDns().split(',').map((s) => s.trim()).filter(Boolean) : undefined;
    this.agentService
      .configureNetwork(this.agentId(), {
        name,
        state: 'present',
        method: this.cfgMethod(),
        address: this.cfgMethod() === 'static' ? this.cfgAddr().trim() || undefined : undefined,
        gateway: this.cfgMethod() === 'static' ? this.cfgGw().trim() || undefined : undefined,
        dns: this.cfgMethod() === 'static' ? dns : undefined,
        dry_run: this.dryRun(),
      })
      .subscribe({
        next: (res) => {
          this.busy.set(false);
          const r = res.result as { changed?: boolean; msg?: string } | undefined;
          this.msg.set(`${r?.msg ?? 'ok'}${this.dryRun() ? ' (dry-run)' : ''}`);
          if (!this.dryRun()) this.reload();
        },
        error: (e) => {
          this.busy.set(false);
          this.err.set(e?.error?.detail ?? 'configure failed');
        },
      });
  }
}
