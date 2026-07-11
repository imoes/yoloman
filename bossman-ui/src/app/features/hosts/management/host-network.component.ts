import { Component, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';
import { NetworkResponse } from '../../../core/models/agent.model';

/** Block J4e — the Network section, redesigned in a RHEL-Cockpit style:
 * card-based, an Interfaces table with status pills + address chips and a
 * per-interface Configure action, and Routes / DNS as side cards. Configure
 * (NetworkManager) still defaults to dry-run and fails cleanly without nmcli. */
@Component({
  selector: 'app-host-network',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-mgmt-section">
      @if (loading()) {
        <div class="bm-mgmt-loading"><mat-spinner diameter="28" /></div>
      } @else if (loadErr()) {
        <p class="bm-svc-err">{{ loadErr() }}</p>
      } @else if (data(); as n) {
        <!-- Interfaces -->
        <section class="bm-card">
          <header class="bm-card-head">
            <h3>Interfaces</h3>
            <span class="bm-spacer"></span>
            <button mat-stroked-button (click)="reload()" [disabled]="loading()"><mat-icon>refresh</mat-icon> Reload</button>
          </header>
          <table class="bm-ct">
            <thead><tr><th>Interface</th><th>Status</th><th>IP addresses</th><th></th></tr></thead>
            <tbody>
              @for (i of n.interfaces; track i.name) {
                <tr>
                  <td class="bm-dev"><mat-icon class="bm-dev-ic">lan</mat-icon>{{ i.name }}</td>
                  <td><span class="bm-pill" [class.bm-up]="i.state === 'UP'" [class.bm-down]="i.state !== 'UP'">{{ i.state === 'UP' ? 'Up' : (i.state || 'Down') }}</span></td>
                  <td>
                    @for (a of i.addresses; track a.cidr) { <span class="bm-chip">{{ a.cidr }}</span> }
                    @if (!i.addresses.length) { <span class="bm-muted">—</span> }
                  </td>
                  <td class="bm-right"><button mat-button class="bm-cfg-btn" (click)="configure(i.name)"><mat-icon>settings</mat-icon> Configure</button></td>
                </tr>
              }
            </tbody>
          </table>
        </section>

        <!-- Configure (Cockpit-style inline panel) -->
        @if (showForm()) {
          <section class="bm-card">
            <header class="bm-card-head"><h3>Configure {{ cfgName() || 'interface' }}</h3></header>
            <div class="bm-form">
              <div class="bm-frow">
                <label>Interface</label>
                <input type="text" placeholder="eth0" [value]="cfgName()" (input)="cfgName.set($any($event.target).value)" />
              </div>
              <div class="bm-frow">
                <label>IPv4 method</label>
                <select [value]="cfgMethod()" (change)="cfgMethod.set($any($event.target).value)">
                  <option value="dhcp">Automatic (DHCP)</option>
                  <option value="static">Manual (static)</option>
                </select>
              </div>
              @if (cfgMethod() === 'static') {
                <div class="bm-frow"><label>Address (CIDR)</label><input type="text" placeholder="10.0.0.5/24" [value]="cfgAddr()" (input)="cfgAddr.set($any($event.target).value)" /></div>
                <div class="bm-frow"><label>Gateway</label><input type="text" placeholder="10.0.0.1 (optional)" [value]="cfgGw()" (input)="cfgGw.set($any($event.target).value)" /></div>
                <div class="bm-frow"><label>DNS</label><input type="text" placeholder="1.1.1.1, 8.8.8.8 (optional)" [value]="cfgDns()" (input)="cfgDns.set($any($event.target).value)" /></div>
              }
              <div class="bm-factions">
                <label class="bm-chk"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> Dry run (preview only)</label>
                <span class="bm-spacer"></span>
                @if (msg()) { <span class="bm-svc-ok">{{ msg() }}</span> }
                @if (err()) { <span class="bm-svc-err">{{ err() }}</span> }
                <button mat-button (click)="showForm.set(false)">Cancel</button>
                <button mat-raised-button color="primary" (click)="apply()" [disabled]="busy() || !cfgName().trim()">Apply</button>
              </div>
            </div>
          </section>
        }

        <!-- Add virtual interface (Cockpit: Add bond/bridge/VLAN) via nmcli -->
        <section class="bm-card">
          <header class="bm-card-head"><h3>Add connection</h3></header>
          <div class="bm-form">
            <div class="bm-frow">
              <label>Type</label>
              <select [value]="connType()" (change)="connType.set($any($event.target).value)">
                <option value="vlan">VLAN</option>
                <option value="bond">Bond</option>
                <option value="bridge">Bridge</option>
                <option value="ethernet">Ethernet</option>
              </select>
            </div>
            <div class="bm-frow"><label>Connection name</label><input type="text" placeholder="e.g. vlan10" [value]="connName()" (input)="connName.set($any($event.target).value)" /></div>
            <div class="bm-frow"><label>Interface name</label><input type="text" placeholder="e.g. eth0.10 / bond0 / br0" [value]="connIf()" (input)="connIf.set($any($event.target).value)" /></div>
            @if (connType() === 'vlan') {
              <div class="bm-frow"><label>Parent device</label><input type="text" placeholder="eth0" [value]="connParent()" (input)="connParent.set($any($event.target).value)" /></div>
              <div class="bm-frow"><label>VLAN ID</label><input type="text" placeholder="10" [value]="connVlanId()" (input)="connVlanId.set($any($event.target).value)" /></div>
            }
            @if (connType() === 'bond') {
              <div class="bm-frow"><label>Mode</label>
                <select [value]="connMode()" (change)="connMode.set($any($event.target).value)">
                  <option value="active-backup">active-backup</option>
                  <option value="balance-rr">balance-rr</option>
                  <option value="802.3ad">802.3ad (LACP)</option>
                  <option value="balance-xor">balance-xor</option>
                </select>
              </div>
            }
            <div class="bm-factions">
              <label class="bm-chk"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> Dry run (preview only)</label>
              <span class="bm-spacer"></span>
              @if (msg()) { <span class="bm-svc-ok">{{ msg() }}</span> }
              @if (err()) { <span class="bm-svc-err">{{ err() }}</span> }
              <button mat-raised-button color="primary" (click)="createConnection()" [disabled]="busy() || !connName().trim() || !connIf().trim()">Add</button>
            </div>
          </div>
        </section>

        <!-- Routes + DNS side by side -->
        <div class="bm-grid2">
          <section class="bm-card">
            <header class="bm-card-head"><h3>Routes</h3></header>
            <table class="bm-ct">
              <thead><tr><th>Destination</th><th>Gateway</th><th>Device</th></tr></thead>
              <tbody>
                @for (r of n.routes; track r.raw) { <tr><td class="bm-dev">{{ r.dest }}</td><td>{{ r.gateway || '—' }}</td><td class="bm-mono">{{ r.dev || '—' }}</td></tr> }
              </tbody>
            </table>
          </section>
          <section class="bm-card">
            <header class="bm-card-head"><h3>DNS</h3></header>
            <div class="bm-kv"><span class="bm-k">Nameservers</span><span>@for (s of n.dns.nameservers || []; track s) { <span class="bm-chip">{{ s }}</span> }@if (!(n.dns.nameservers || []).length) { — }</span></div>
            <div class="bm-kv"><span class="bm-k">Search</span><span>{{ (n.dns.search || []).join(', ') || '—' }}</span></div>
          </section>
        </div>
      }
    </div>
  `,
  styles: [
    `
      .bm-mgmt-section { padding: 4px 0; display: flex; flex-direction: column; gap: 16px; }
      .bm-mgmt-loading { display: flex; justify-content: center; padding: 24px; }
      .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; background: var(--mat-sys-surface); }
      .bm-card-head { display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-card-head h3 { margin: 0; font-size: 14px; font-weight: 600; }
      .bm-spacer { flex: 1; }
      .bm-grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
      @media (max-width: 900px) { .bm-grid2 { grid-template-columns: 1fr; } }
      .bm-ct { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-ct th { text-align: left; font-weight: 500; opacity: 0.6; padding: 6px 14px; font-size: 12px; }
      .bm-ct td { padding: 8px 14px; border-top: 1px solid var(--mat-sys-outline-variant); vertical-align: middle; }
      .bm-right { text-align: right; }
      .bm-dev { font-family: monospace; font-weight: 600; display: flex; align-items: center; gap: 6px; }
      .bm-dev-ic { font-size: 17px; width: 17px; height: 17px; opacity: 0.6; }
      .bm-mono { font-family: monospace; }
      .bm-muted { opacity: 0.5; }
      .bm-pill { font-size: 11.5px; padding: 2px 10px; border-radius: 999px; font-weight: 500; }
      .bm-pill.bm-up { background: color-mix(in srgb, var(--bm-green, #2e7d32) 20%, transparent); color: var(--bm-green, #2e7d32); }
      .bm-pill.bm-down { background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); opacity: 0.8; }
      .bm-chip { display: inline-block; font-family: monospace; font-size: 12px; padding: 1px 8px; margin: 1px 4px 1px 0; border-radius: 6px; background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
      .bm-cfg-btn { font-size: 12.5px; }
      .bm-form { padding: 12px 14px; display: flex; flex-direction: column; gap: 10px; }
      .bm-frow { display: grid; grid-template-columns: 130px 1fr; align-items: center; gap: 10px; max-width: 560px; }
      .bm-frow label { font-size: 13px; opacity: 0.8; }
      .bm-frow input, .bm-frow select { padding: 7px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; }
      .bm-factions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-top: 4px; }
      .bm-chk { font-size: 12.5px; opacity: 0.85; display: flex; align-items: center; gap: 5px; }
      .bm-kv { display: flex; gap: 12px; padding: 8px 14px; font-size: 13px; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-kv:first-of-type { border-top: none; }
      .bm-k { width: 110px; opacity: 0.6; }
      .bm-svc-ok { color: var(--bm-green, #2e7d32); font-size: 12px; }
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
  showForm = signal(false);

  cfgName = signal('');
  cfgMethod = signal<'dhcp' | 'static'>('dhcp');
  cfgAddr = signal('');
  cfgGw = signal('');
  cfgDns = signal('');
  dryRun = signal(true);

  connType = signal<'vlan' | 'bond' | 'bridge' | 'ethernet'>('vlan');
  connName = signal('');
  connIf = signal('');
  connParent = signal('');
  connVlanId = signal('');
  connMode = signal('active-backup');

  loadOnce(): void {
    if (this.loaded() || this.loading()) return;
    this.reload();
  }

  configure(name: string): void {
    this.cfgName.set(name);
    this.msg.set(null);
    this.err.set(null);
    this.showForm.set(true);
  }

  reload(): void {
    this.loading.set(true);
    this.loadErr.set(null);
    this.agentService.network(this.agentId()).subscribe({
      next: (res) => { this.data.set(res); this.loading.set(false); this.loaded.set(true); },
      error: (e) => { this.loading.set(false); this.loaded.set(true); this.loadErr.set(e?.error?.detail ?? 'failed to load network'); },
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
        error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail ?? 'configure failed'); },
      });
  }

  /** Create a virtual interface (VLAN/bond/bridge/ethernet) via the nmcli
   * module — Cockpit's Add bond/bridge/VLAN. Dry-run by default. */
  createConnection(): void {
    const params: Record<string, unknown> = {
      type: this.connType(),
      conn_name: this.connName().trim(),
      ifname: this.connIf().trim(),
      state: 'present',
      dry_run: this.dryRun(),
    };
    if (this.connType() === 'vlan') {
      params['vlandev'] = this.connParent().trim();
      params['vlanid'] = Number(this.connVlanId().trim()) || undefined;
    }
    if (this.connType() === 'bond') params['mode'] = this.connMode();
    this.busy.set(true);
    this.msg.set(null);
    this.err.set(null);
    this.agentService.callTool(this.agentId(), 'community.general.nmcli', params).subscribe({
      next: (res) => {
        this.busy.set(false);
        const r = res.result as { msg?: string } | undefined;
        this.msg.set(`added ${this.connName().trim()}: ${r?.msg ?? 'ok'}${this.dryRun() ? ' (dry-run)' : ''}`);
        if (!this.dryRun()) this.reload();
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail ?? 'add failed'); },
    });
  }
}
