import { Component, computed, inject, input, signal } from '@angular/core';
import { switchMap, tap } from 'rxjs';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';
import { NetInterface, NetworkResponse } from '../../../core/models/agent.model';
import { ConfigDialogService } from '../../../shared/config-dialog/config-dialog.service';
import { FieldValues } from '../../../shared/config-dialog/config-dialog.types';

/** Block J4e, Cockpit-adaptation — the Network section restructured like
 * Cockpit's networkmanager (../cockpit/pkg/networkmanager): an Interfaces
 * table where selecting an interface reveals a description-list detail card
 * with a per-facet inline "Edit" (IPv4, MTU, MAC), each opening a focused
 * config dialog (the shared dialog framework). Provider-independent: the agent
 * module auto-detects NetworkManager/netplan/systemd-networkd/ifupdown. Dry-run
 * is the interim safety net until the checkpoint/auto-rollback module lands. */
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
        @if (pending(); as p) {
          <div class="bm-ckpt">
            <mat-icon>warning</mat-icon>
            <span>Applied to <strong>{{ p.name }}</strong>. Keep the change? Auto-reverting in <strong>{{ p.left }}s</strong> if your connection dropped.</span>
            <span class="bm-spacer"></span>
            <button mat-stroked-button (click)="revertNow()">Revert now</button>
            <button mat-raised-button color="primary" (click)="keepChanges()">Keep changes</button>
          </div>
        }
        <!-- Interfaces -->
        <section class="bm-card">
          <header class="bm-card-head">
            <h3>Interfaces</h3>
            @if (n.provider && n.provider !== 'unknown') {
              <span class="bm-prov" [title]="'Network is managed by ' + providerLabel(n.provider)"><mat-icon class="bm-prov-ic">hub</mat-icon>{{ providerLabel(n.provider) }}</span>
            } @else if (n.provider === 'unknown') {
              <span class="bm-prov bm-prov-none" title="No supported network provider detected — configuration is unavailable">no provider detected</span>
            }
            <span class="bm-spacer"></span>
            <button mat-stroked-button (click)="reload()" [disabled]="loading()"><mat-icon>refresh</mat-icon> Reload</button>
          </header>
          <table class="bm-ct">
            <thead><tr><th>Interface</th><th>Status</th><th>IP addresses</th></tr></thead>
            <tbody>
              @for (i of n.interfaces; track i.name) {
                <tr class="bm-ifrow" [class.bm-sel]="selected() === i.name" (click)="select(i.name)">
                  <td class="bm-dev"><mat-icon class="bm-dev-ic">lan</mat-icon>{{ i.name }}</td>
                  <td><span class="bm-pill" [class.bm-up]="i.state === 'UP'" [class.bm-down]="i.state !== 'UP'">{{ i.state === 'UP' ? 'Up' : (i.state || 'Down') }}</span></td>
                  <td>
                    @for (a of i.addresses; track a.cidr) { <span class="bm-chip">{{ a.cidr }}</span> }
                    @if (!i.addresses.length) { <span class="bm-muted">—</span> }
                  </td>
                </tr>
              }
            </tbody>
          </table>
        </section>

        <!-- Detail (Cockpit-style description list with inline edit per facet) -->
        @if (sel(); as i) {
          <section class="bm-card">
            <header class="bm-card-head">
              <h3>{{ i.name }}</h3>
              <span class="bm-pill" [class.bm-up]="i.state === 'UP'" [class.bm-down]="i.state !== 'UP'">{{ i.state === 'UP' ? 'Up' : (i.state || 'Down') }}</span>
              <span class="bm-spacer"></span>
              @if (msg()) { <span class="bm-svc-ok">{{ msg() }}</span> }
              @if (err()) { <span class="bm-svc-err">{{ err() }}</span> }
            </header>
            <dl class="bm-dl">
              <div class="bm-dlrow">
                <dt>IPv4</dt>
                <dd>
                  <span class="bm-dlval">{{ ipv4Summary(i) }}</span>
                  <button mat-button class="bm-edit" (click)="editIpv4(i)"><mat-icon>edit</mat-icon> Edit</button>
                </dd>
              </div>
              <div class="bm-dlrow">
                <dt>IPv6</dt>
                <dd><span class="bm-dlval">{{ ipv6Summary(i) }}</span></dd>
              </div>
              <div class="bm-dlrow">
                <dt>MTU</dt>
                <dd>
                  <span class="bm-dlval">{{ i.mtu || 'Automatic' }}</span>
                  <button mat-button class="bm-edit" (click)="editMtu(i)"><mat-icon>edit</mat-icon> Edit</button>
                </dd>
              </div>
              <div class="bm-dlrow">
                <dt>MAC</dt>
                <dd>
                  <span class="bm-dlval bm-mono">{{ i.mac || '—' }}</span>
                  <button mat-button class="bm-edit" (click)="editMac(i)"><mat-icon>edit</mat-icon> Edit</button>
                </dd>
              </div>
            </dl>
          </section>
        }

        <!-- Add virtual interface (Cockpit: Add bond/bridge/VLAN) via nmcli.
             nmcli-only, so only offered on NetworkManager hosts. -->
        @if (n.provider === 'networkmanager') {
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
              <button mat-raised-button color="primary" (click)="createConnection()" [disabled]="busy() || !connName().trim() || !connIf().trim()">Add</button>
            </div>
          </div>
        </section>
        }

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
      .bm-ifrow { cursor: pointer; }
      .bm-ifrow:hover { background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent); }
      .bm-sel { background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
      .bm-dev { font-family: monospace; font-weight: 600; display: flex; align-items: center; gap: 6px; }
      .bm-dev-ic { font-size: 17px; width: 17px; height: 17px; opacity: 0.6; }
      .bm-mono { font-family: monospace; }
      .bm-muted { opacity: 0.5; }
      .bm-pill { font-size: 11.5px; padding: 2px 10px; border-radius: 999px; font-weight: 500; }
      .bm-pill.bm-up { background: color-mix(in srgb, var(--bm-green, #2e7d32) 20%, transparent); color: var(--bm-green, #2e7d32); }
      .bm-pill.bm-down { background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); opacity: 0.8; }
      .bm-chip { display: inline-block; font-family: monospace; font-size: 12px; padding: 1px 8px; margin: 1px 4px 1px 0; border-radius: 6px; background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
      .bm-dl { margin: 0; }
      .bm-dlrow { display: grid; grid-template-columns: 120px 1fr; align-items: center; padding: 9px 14px; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-dlrow:first-child { border-top: none; }
      .bm-dlrow dt { font-size: 12.5px; opacity: 0.6; }
      .bm-dlrow dd { margin: 0; display: flex; align-items: center; gap: 10px; font-size: 13px; }
      .bm-dlval { flex: 1; }
      .bm-edit { font-size: 12px; min-width: auto; }
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
      .bm-prov { display: inline-flex; align-items: center; gap: 4px; font-size: 11.5px; padding: 2px 10px; border-radius: 999px; font-weight: 500; background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); color: var(--mat-sys-primary); }
      .bm-prov-ic { font-size: 14px; width: 14px; height: 14px; }
      .bm-prov-none { background: color-mix(in srgb, #c62828 16%, transparent); color: #c62828; }
      .bm-ckpt { display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-radius: 8px; font-size: 13px; background: color-mix(in srgb, #ed6c02 18%, transparent); color: #e65100; }
      .bm-ckpt mat-icon { flex: none; }
    `,
  ],
})
export class HostNetworkComponent {
  private agentService = inject(AgentService);
  private dialogs = inject(ConfigDialogService);

  agentId = input.required<string>();

  data = signal<NetworkResponse | null>(null);
  loading = signal(false);
  loaded = signal(false);
  loadErr = signal<string | null>(null);
  busy = signal(false);
  msg = signal<string | null>(null);
  err = signal<string | null>(null);
  selected = signal<string | null>(null);
  dryRun = signal(true);

  connType = signal<'vlan' | 'bond' | 'bridge' | 'ethernet'>('vlan');
  connName = signal('');
  connIf = signal('');
  connParent = signal('');
  connVlanId = signal('');
  connMode = signal('active-backup');

  /** The currently selected interface object. */
  sel = computed<NetInterface | null>(() => {
    const s = this.selected();
    return s ? (this.data()?.interfaces.find((i) => i.name === s) ?? null) : null;
  });

  providerLabel(p: string): string {
    return (
      { networkmanager: 'NetworkManager', netplan: 'netplan', networkd: 'systemd-networkd', ifupdown: 'ifupdown', unknown: 'unknown' } as Record<string, string>
    )[p] ?? p;
  }

  ipv4Summary(i: NetInterface): string {
    const v4 = i.addresses.filter((a) => a.family === 'inet' || a.cidr.indexOf(':') < 0);
    return v4.length ? v4.map((a) => a.cidr).join(', ') : 'Automatic (DHCP) or none';
  }
  ipv6Summary(i: NetInterface): string {
    const v6 = i.addresses.filter((a) => a.family === 'inet6' || a.cidr.indexOf(':') >= 0);
    return v6.length ? v6.map((a) => a.cidr).join(', ') : '—';
  }

  loadOnce(): void {
    if (this.loaded() || this.loading()) return;
    this.reload();
  }

  select(name: string): void {
    this.selected.set(this.selected() === name ? null : name);
    this.msg.set(null);
    this.err.set(null);
  }

  reload(): void {
    this.loading.set(true);
    this.loadErr.set(null);
    this.agentService.network(this.agentId()).subscribe({
      next: (res) => { this.data.set(res); this.loading.set(false); this.loaded.set(true); },
      error: (e) => { this.loading.set(false); this.loaded.set(true); this.loadErr.set(e?.error?.detail ?? 'failed to load network'); },
    });
  }

  // ---- facet dialogs (via the shared config-dialog framework) ----

  editIpv4(i: NetInterface): void {
    const v4 = i.addresses.find((a) => a.family === 'inet' || a.cidr.indexOf(':') < 0);
    const gw = this.data()?.routes.find((r) => (r.dest === 'default' || r.dest === '0.0.0.0/0') && r.dev === i.name);
    this.dialogs
      .open({
        title: `IPv4 — ${i.name}`,
        fields: [
          { tag: 'method', title: 'IPv4 method', type: 'select', initial: v4 ? 'static' : 'dhcp',
            choices: [{ value: 'dhcp', title: 'Automatic (DHCP)' }, { value: 'static', title: 'Manual (static)' }] },
          { tag: 'address', title: 'Address (CIDR)', type: 'text', initial: v4?.cidr ?? '', placeholder: '10.0.0.5/24',
            visible: (v) => v['method'] === 'static',
            validate: (val, v) => (v['method'] === 'static' && !String(val || '').trim() ? 'Address is required' : null) },
          { tag: 'gateway', title: 'Gateway', type: 'text', initial: gw?.gateway ?? '', placeholder: '10.0.0.1 (optional)', visible: (v) => v['method'] === 'static' },
          { tag: 'dns', title: 'DNS servers', type: 'stringList', initial: this.data()?.dns.nameservers ?? [], placeholder: '1.1.1.1', visible: (v) => v['method'] === 'static' },
          { tag: 'dry_run', title: '', type: 'checkboxes', initial: ['on'], items: [{ tag: 'on', title: 'Dry run (preview only)' }] },
        ],
        submitLabel: 'Apply',
        action: (v) => this.applyIpv4(i.name, v),
      })
      .subscribe((r) => { if (r) { this.msg.set("applied"); this.reload(); } });
  }

  editMtu(i: NetInterface): void {
    this.dialogs
      .open({
        title: `MTU — ${i.name}`,
        fields: [
          { tag: 'mtu', title: 'MTU (bytes)', type: 'text', initial: String(i.mtu || 1500), placeholder: '1500',
            validate: (val) => (String(val || '').trim() && isNaN(Number(val)) ? 'MTU must be a number' : null) },
          { tag: 'dry_run', title: '', type: 'checkboxes', initial: ['on'], items: [{ tag: 'on', title: 'Dry run (preview only)' }] },
        ],
        submitLabel: 'Apply',
        action: (v) => this.applyFacet(i, { mtu: Number(v['mtu']) || undefined }, v),
      })
      .subscribe((r) => { if (r) { this.msg.set("applied"); this.reload(); } });
  }

  editMac(i: NetInterface): void {
    this.dialogs
      .open({
        title: `MAC — ${i.name}`,
        fields: [
          { tag: 'mac', title: 'MAC address', type: 'text', initial: i.mac ?? '', placeholder: 'aa:bb:cc:dd:ee:ff' },
          { tag: 'dry_run', title: '', type: 'checkboxes', initial: ['on'], items: [{ tag: 'on', title: 'Dry run (preview only)' }] },
        ],
        submitLabel: 'Apply',
        action: (v) => this.applyFacet(i, { mac: String(v['mac'] || '').trim() || undefined }, v),
      })
      .subscribe((r) => { if (r) { this.msg.set("applied"); this.reload(); } });
  }

  /** IPv4 apply: builds a full present-config from the dialog values. */
  private applyIpv4(name: string, v: FieldValues) {
    const method = v['method'] === 'static' ? 'static' : 'dhcp';
    const dns = (v['dns'] as string[] | undefined)?.map((s) => s.trim()).filter(Boolean);
    return this.safeConfigure(name, {
      name, state: 'present', method,
      address: method === 'static' ? String(v['address'] || '').trim() || undefined : undefined,
      gateway: method === 'static' ? String(v['gateway'] || '').trim() || undefined : undefined,
      dns: method === 'static' ? (dns?.length ? dns : undefined) : undefined,
      dry_run: this.isDry(v),
    });
  }

  /** MTU/MAC apply: keep the existing method, just add the facet. Infers the
   * current v4 method from the presence of a static address. */
  private applyFacet(i: NetInterface, extra: { mtu?: number; mac?: string }, v: FieldValues) {
    const v4 = i.addresses.find((a) => a.family === 'inet' || a.cidr.indexOf(':') < 0);
    return this.safeConfigure(i.name, {
      name: i.name, state: 'present',
      method: v4 ? 'static' : 'dhcp',
      address: v4 ? v4.cidr : undefined,
      ...extra,
      dry_run: this.isDry(v),
    });
  }

  /** Cockpit-style safe apply: for a real (non-dry-run) change, arm a
   * yoloman.network_checkpoint auto-revert BEFORE applying, then start the
   * "keep changes / reverting in Ns" countdown so a lost connection self-heals. */
  private safeConfigure(name: string, cfg: { dry_run?: boolean; [k: string]: unknown }) {
    if (cfg.dry_run) return this.agentService.configureNetwork(this.agentId(), cfg as any);
    const id = `ck-${name}-${Date.now()}`;
    const timeout = 90;
    return this.agentService
      .callTool(this.agentId(), 'yoloman.network_checkpoint', { state: 'create', name, id, timeout })
      .pipe(
        switchMap(() => this.agentService.configureNetwork(this.agentId(), cfg as any)),
        tap(() => this.armCountdown(id, name, timeout)),
      );
  }

  private isDry(v: FieldValues): boolean {
    return (v['dry_run'] as string[] | undefined)?.includes('on') ?? true;
  }

  // ---- checkpoint countdown (Cockpit "connection will be lost" safety) ----
  pending = signal<{ id: string; name: string; left: number } | null>(null);
  private pendingTimer: any = null;

  private armCountdown(id: string, name: string, secs: number): void {
    this.clearCountdown();
    this.pending.set({ id, name, left: secs });
    this.pendingTimer = setInterval(() => {
      const p = this.pending();
      if (!p) return;
      const left = p.left - 1;
      if (left <= 0) { this.clearCountdown(); this.pending.set(null); this.reload(); }
      else this.pending.set({ ...p, left });
    }, 1000);
  }

  private clearCountdown(): void {
    if (this.pendingTimer) { clearInterval(this.pendingTimer); this.pendingTimer = null; }
  }

  keepChanges(): void {
    const p = this.pending();
    if (!p) return;
    this.agentService.callTool(this.agentId(), 'yoloman.network_checkpoint', { state: 'confirm', id: p.id }).subscribe({
      next: () => { this.clearCountdown(); this.pending.set(null); this.msg.set('changes kept'); },
      error: (e) => this.err.set(e?.error?.detail ?? 'confirm failed'),
    });
  }

  revertNow(): void {
    const p = this.pending();
    if (!p) return;
    this.agentService.callTool(this.agentId(), 'yoloman.network_checkpoint', { state: 'rollback', id: p.id }).subscribe({
      next: () => { this.clearCountdown(); this.pending.set(null); this.msg.set('reverted'); this.reload(); },
      error: (e) => this.err.set(e?.error?.detail ?? 'rollback failed'),
    });
  }

  createConnection(): void {
    const params: Record<string, unknown> = {
      type: this.connType(), conn_name: this.connName().trim(), ifname: this.connIf().trim(),
      state: 'present', dry_run: this.dryRun(),
    };
    if (this.connType() === 'vlan') { params['vlandev'] = this.connParent().trim(); params['vlanid'] = Number(this.connVlanId().trim()) || undefined; }
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
