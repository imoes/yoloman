import { Component, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';

interface FwState {
  backend: string;
  firewalld: string;
  ufw: string;
  iptables: string;
  ip_forward: boolean;
  router_mode: boolean;
}

/**
 * Unified firewall snapin — as simple as firewall-cmd, over whichever backend
 * the host runs (firewalld / ufw / iptables, auto-detected by the `firewall`
 * agent module). Allow/deny a port or service, SNAT/DNAT, and flip
 * server↔router mode (IP forwarding + masquerade). Enabling the firewall
 * whitelists the management ("Yoloman") port first. Writes default to dry-run.
 */
@Component({
  selector: 'app-host-firewall',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-fw">
      <div class="bm-topbar">
        @if (state(); as st) {
          <span class="bm-badge" [class.bm-on]="isActive(st)">Backend: <b>{{ st.backend }}</b></span>
          <span class="bm-badge">{{ st.router_mode ? 'Router mode (forwarding on)' : 'Server mode' }}</span>
        } @else if (loading()) {
          <mat-spinner diameter="18" />
        }
        <button mat-stroked-button (click)="detect()" [disabled]="loading()"><mat-icon>refresh</mat-icon> Detect</button>
        <label class="bm-chk"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> Dry run</label>
        <span class="bm-spacer"></span>
        <button mat-raised-button color="primary" (click)="op('enable', {})" [disabled]="busy()"><mat-icon>shield</mat-icon> Enable</button>
        <button mat-button (click)="op('disable', {})" [disabled]="busy()">Disable</button>
      </div>
      @if (msg()) { <div class="bm-ok">{{ msg() }}</div> }
      @if (err()) { <div class="bm-err">{{ err() }}</div> }

      <div class="bm-grid2">
        <section class="bm-card">
          <header><h3>Allow / Deny</h3></header>
          <div class="bm-form">
            <input placeholder="port (e.g. 8080/tcp)" [value]="port()" (input)="port.set($any($event.target).value)" />
            <div class="bm-or">or</div>
            <input placeholder="service (e.g. ssh, https, dns)" [value]="service()" (input)="service.set($any($event.target).value)" />
            <input placeholder="from source CIDR (optional)" [value]="source()" (input)="source.set($any($event.target).value)" />
            <div class="bm-actions">
              <button mat-stroked-button (click)="allowDeny('allow')" [disabled]="busy() || (!port().trim() && !service().trim())"><mat-icon>check</mat-icon> Allow</button>
              <button mat-button (click)="allowDeny('deny')" [disabled]="busy() || (!port().trim() && !service().trim())"><mat-icon>block</mat-icon> Deny</button>
            </div>
          </div>
        </section>

        <section class="bm-card">
          <header><h3>Server / Router mode</h3></header>
          <div class="bm-form">
            <label class="bm-radio"><input type="radio" name="mode" [checked]="mode()==='server'" (change)="mode.set('server')" /> Server (no forwarding)</label>
            <label class="bm-radio"><input type="radio" name="mode" [checked]="mode()==='router'" (change)="mode.set('router')" /> Router (forwarding + masquerade)</label>
            @if (mode()==='router') {
              <input placeholder="WAN interface (e.g. eth0)" [value]="wanIf()" (input)="wanIf.set($any($event.target).value)" />
              <input placeholder="LAN subnet to masquerade (e.g. 10.0.0.0/24)" [value]="lanSubnet()" (input)="lanSubnet.set($any($event.target).value)" />
            }
            <div class="bm-actions">
              <button mat-stroked-button (click)="applyMode()" [disabled]="busy()"><mat-icon>router</mat-icon> Apply mode</button>
            </div>
          </div>
        </section>

        <section class="bm-card">
          <header><h3>SNAT / Masquerade (outbound)</h3></header>
          <div class="bm-form">
            <input placeholder="source CIDR (optional)" [value]="snatSource()" (input)="snatSource.set($any($event.target).value)" />
            <input placeholder="to-source: IP or 'masquerade'" [value]="toSource()" (input)="toSource.set($any($event.target).value)" />
            <input placeholder="out interface (e.g. eth0)" [value]="snatOut()" (input)="snatOut.set($any($event.target).value)" />
            <div class="bm-actions"><button mat-stroked-button (click)="snat()" [disabled]="busy() || !toSource().trim()"><mat-icon>swap_horiz</mat-icon> Add SNAT</button></div>
          </div>
        </section>

        <section class="bm-card">
          <header><h3>DNAT / Port-forward (inbound)</h3></header>
          <div class="bm-form">
            <input placeholder="in interface (e.g. eth0)" [value]="dnatIn()" (input)="dnatIn.set($any($event.target).value)" />
            <input placeholder="protocol (tcp/udp)" [value]="dnatProto()" (input)="dnatProto.set($any($event.target).value)" />
            <input placeholder="incoming port (e.g. 443)" [value]="dnatPort()" (input)="dnatPort.set($any($event.target).value)" />
            <input placeholder="to destination ip:port" [value]="toDest()" (input)="toDest.set($any($event.target).value)" />
            <div class="bm-actions"><button mat-stroked-button (click)="dnat()" [disabled]="busy() || !dnatPort().trim() || !toDest().trim()"><mat-icon>login</mat-icon> Add DNAT</button></div>
          </div>
        </section>
      </div>

      <section class="bm-card">
        <header class="bm-cardhead"><h3>Active rules</h3><button mat-button (click)="list()" [disabled]="busy()"><mat-icon>list</mat-icon> Refresh</button></header>
        @if (rules()) { <pre class="bm-raw">{{ rules() }}</pre> } @else { <p class="bm-empty">Click “Refresh” to read current rules.</p> }
      </section>
    </div>
  `,
  styles: [`
    .bm-fw { display: flex; flex-direction: column; gap: 16px; padding: 4px 0; }
    .bm-topbar { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
    .bm-spacer { flex: 1; }
    .bm-badge { font-size: 12px; padding: 3px 9px; border-radius: 20px; border: 1px solid var(--mat-sys-outline-variant); }
    .bm-badge.bm-on { background: color-mix(in srgb, var(--bm-green,#2e7d32) 18%, transparent); border-color: transparent; }
    .bm-chk, .bm-radio { font-size: 12.5px; display: flex; align-items: center; gap: 5px; }
    .bm-grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
    @media (max-width: 900px) { .bm-grid2 { grid-template-columns: 1fr; } }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; background: var(--mat-sys-surface); }
    .bm-card > header, .bm-cardhead { padding: 9px 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); display: flex; align-items: center; justify-content: space-between; }
    .bm-card h3 { margin: 0; font-size: 14px; font-weight: 600; }
    .bm-form { padding: 12px 14px; display: flex; flex-direction: column; gap: 9px; }
    .bm-form input[type=text], .bm-form input:not([type]) { padding: 7px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; }
    .bm-or { font-size: 11px; opacity: 0.5; text-align: center; }
    .bm-actions { display: flex; gap: 8px; margin-top: 2px; }
    .bm-raw { max-height: 40vh; overflow: auto; background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); padding: 10px 12px; border-radius: 6px; font-size: 12px; margin: 12px 14px; white-space: pre-wrap; }
    .bm-empty { opacity: 0.6; padding: 12px 14px; font-size: 13px; }
    .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; }
    .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
  `],
})
export class HostFirewallComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  dryRun = signal(true);
  msg = signal<string | null>(null);
  err = signal<string | null>(null);
  state = signal<FwState | null>(null);
  rules = signal<string>('');

  port = signal(''); service = signal(''); source = signal('');
  mode = signal<'server' | 'router'>('server');
  wanIf = signal(''); lanSubnet = signal('');
  snatSource = signal(''); toSource = signal(''); snatOut = signal('');
  dnatIn = signal(''); dnatProto = signal('tcp'); dnatPort = signal(''); toDest = signal('');

  isActive(st: FwState): boolean { return st.firewalld === 'running' || st.ufw === 'active'; }

  loadOnce(): void { if (!this.loaded()) { this.loaded.set(true); this.detect(); } }

  detect(): void {
    this.loading.set(true); this.err.set(null);
    this.call('detect', {}, (data) => {
      const st = data as FwState;
      this.state.set(st);
      this.mode.set(st.router_mode ? 'router' : 'server');
    }, () => this.loading.set(false));
  }

  list(): void {
    this.busy.set(true);
    this.call('list', {}, (data) => this.rules.set((data as { rules?: string })?.rules || '(no output)'), () => this.busy.set(false));
  }

  allowDeny(op: 'allow' | 'deny'): void {
    const p: Record<string, unknown> = {};
    if (this.port().trim()) p['port'] = this.port().trim();
    if (this.service().trim()) p['service'] = this.service().trim();
    if (this.source().trim()) p['source'] = this.source().trim();
    this.op(op, p);
  }

  applyMode(): void {
    const p: Record<string, unknown> = { mode: this.mode() };
    if (this.mode() === 'router') {
      if (this.wanIf().trim()) p['out_interface'] = this.wanIf().trim();
      if (this.lanSubnet().trim()) p['lan_subnet'] = this.lanSubnet().trim();
    }
    this.op('set_mode', p);
  }

  snat(): void {
    const p: Record<string, unknown> = { to_source: this.toSource().trim() };
    if (this.snatSource().trim()) p['source'] = this.snatSource().trim();
    if (this.snatOut().trim()) p['out_interface'] = this.snatOut().trim();
    this.op('snat', p);
  }

  dnat(): void {
    const p: Record<string, unknown> = { dest_port: this.dnatPort().trim(), to_dest: this.toDest().trim(), protocol: this.dnatProto().trim() || 'tcp' };
    if (this.dnatIn().trim()) p['in_interface'] = this.dnatIn().trim();
    this.op('dnat', p);
  }

  /** Run a mutating op, then refresh state + rules. */
  op(operation: string, extra: Record<string, unknown>): void {
    this.busy.set(true);
    this.call(operation, extra, (_data, res) => {
      this.msg.set((res as { msg?: string })?.msg || `${operation} ok`);
    }, () => { this.busy.set(false); if (!this.dryRun()) { this.detect(); this.list(); } });
  }

  private call(op: string, extra: Record<string, unknown>, ok: (data: unknown, res: unknown) => void, done: () => void): void {
    this.msg.set(null); this.err.set(null);
    this.agentService.callTool(this.agentId(), 'firewall', { op, dry_run: this.dryRun(), ...extra }).subscribe({
      next: (res) => { const r = res.result as { data?: unknown }; ok(r?.data, res.result); done(); },
      error: (e) => { this.err.set(e?.error?.detail ?? `firewall ${op} failed`); done(); },
    });
  }
}
