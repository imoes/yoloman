import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../../../core/services/agent.service';
import { ConfigResource } from '../../../../core/models/agent.model';

interface Subnet { network: string; netmask: string; range_start: string; range_end: string; routers: string; dns: string; }
interface Host { name: string; mac: string; ip: string; }
interface Lease { ip: string; mac: string; ends: string; state: string; }

const DHCPD_PATH = '/etc/dhcp/dhcpd.conf';
const LEASES_PATH = '/var/lib/dhcp/dhcpd.leases';

/**
 * ISC DHCP server snapin — manage scopes (subnet blocks) and reservations
 * (host blocks) in /etc/dhcp/dhcpd.conf through the `dhcpd` codec, and
 * list/delete active leases. Save writes the config (codec round-trip,
 * unmodeled blocks preserved) then restarts isc-dhcp-server. Deleting a lease
 * stops the server, strips the lease stanza, and starts it again.
 */
@Component({
  selector: 'app-dhcpd',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="bm-dhcp">
      @if (loading()) { <p class="bm-dim">Loading {{ path }}…</p> }
      @else if (!installed()) {
        <div class="bm-install">
          <p>isc-dhcp-server is not configured on this host ({{ path }} not found).</p>
          <button mat-raised-button color="primary" (click)="install()" [disabled]="busy()"><mat-icon>download</mat-icon> Install isc-dhcp-server</button>
          @if (err()) { <span class="bm-err">{{ err() }}</span> }
        </div>
      } @else {
        <div class="bm-head">
          <span class="bm-dim">{{ path }}</span>
          <span class="bm-spacer"></span>
          <label class="bm-dry"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
          <button mat-raised-button color="primary" (click)="save()" [disabled]="busy()">{{ dryRun() ? 'Preview' : 'Save + restart' }}</button>
          @if (msg()) { <span class="bm-ok">{{ msg() }}</span> }
          @if (err()) { <span class="bm-err">{{ err() }}</span> }
        </div>

        <section class="bm-card">
          <header><h3>Scopes (subnets)</h3></header>
          <table class="bm-t">
            <thead><tr><th>Network</th><th>Netmask</th><th>Range start</th><th>Range end</th><th>Routers</th><th>DNS</th><th></th></tr></thead>
            <tbody>
              @for (s of subnets(); track $index) {
                <tr>
                  <td><input [value]="s.network" (input)="setSub($index,'network',$any($event.target).value)" placeholder="10.0.0.0" /></td>
                  <td><input [value]="s.netmask" (input)="setSub($index,'netmask',$any($event.target).value)" placeholder="255.255.255.0" /></td>
                  <td><input [value]="s.range_start" (input)="setSub($index,'range_start',$any($event.target).value)" placeholder="10.0.0.100" /></td>
                  <td><input [value]="s.range_end" (input)="setSub($index,'range_end',$any($event.target).value)" placeholder="10.0.0.200" /></td>
                  <td><input [value]="s.routers" (input)="setSub($index,'routers',$any($event.target).value)" placeholder="10.0.0.1" /></td>
                  <td><input [value]="s.dns" (input)="setSub($index,'dns',$any($event.target).value)" placeholder="10.0.0.1" /></td>
                  <td><button class="bm-x" (click)="removeSub($index)" title="Remove scope">✕</button></td>
                </tr>
              }
              @if (!subnets().length) { <tr><td colspan="7" class="bm-dim">No scopes yet.</td></tr> }
            </tbody>
          </table>
          <button mat-button (click)="addSub()"><mat-icon>add</mat-icon> Add scope</button>
        </section>

        <section class="bm-card">
          <header><h3>Reservations (static hosts)</h3></header>
          <table class="bm-t">
            <thead><tr><th>Name</th><th>MAC</th><th>Fixed IP</th><th></th></tr></thead>
            <tbody>
              @for (h of hosts(); track $index) {
                <tr>
                  <td><input [value]="h.name" (input)="setHost($index,'name',$any($event.target).value)" placeholder="printer" /></td>
                  <td><input [value]="h.mac" (input)="setHost($index,'mac',$any($event.target).value)" placeholder="00:11:22:33:44:55" /></td>
                  <td><input [value]="h.ip" (input)="setHost($index,'ip',$any($event.target).value)" placeholder="10.0.0.50" /></td>
                  <td><button class="bm-x" (click)="removeHost($index)" title="Remove reservation">✕</button></td>
                </tr>
              }
              @if (!hosts().length) { <tr><td colspan="4" class="bm-dim">No reservations yet.</td></tr> }
            </tbody>
          </table>
          <button mat-button (click)="addHost()"><mat-icon>add</mat-icon> Add reservation</button>
        </section>

        <section class="bm-card">
          <header class="bm-cardhead"><h3>Active leases</h3><button mat-button (click)="loadLeases()" [disabled]="busy()"><mat-icon>refresh</mat-icon> Refresh</button></header>
          <table class="bm-t">
            <thead><tr><th>IP</th><th>MAC</th><th>Ends</th><th>State</th><th></th></tr></thead>
            <tbody>
              @for (l of leases(); track l.ip) {
                <tr>
                  <td>{{ l.ip }}</td><td>{{ l.mac }}</td><td>{{ l.ends }}</td><td>{{ l.state }}</td>
                  <td><button class="bm-x" (click)="deleteLease(l)" [disabled]="busy()" title="Delete lease (stops+restarts server)">🗑</button></td>
                </tr>
              }
              @if (!leases().length) { <tr><td colspan="5" class="bm-dim">No active leases (or none loaded).</td></tr> }
            </tbody>
          </table>
        </section>
      }
    </div>
  `,
  styles: [`
    .bm-dhcp { display: flex; flex-direction: column; gap: 16px; }
    .bm-head { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    .bm-spacer { flex: 1; } .bm-dry { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .bm-install { display: flex; flex-direction: column; gap: 12px; align-items: flex-start; padding: 12px 0; }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; }
    .bm-card > header, .bm-cardhead { padding: 9px 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); display: flex; align-items: center; justify-content: space-between; }
    .bm-card h3 { margin: 0; font-size: 14px; font-weight: 600; }
    .bm-t { width: 100%; border-collapse: collapse; }
    .bm-t th { text-align: left; font-size: 12px; opacity: 0.7; padding: 5px 8px; }
    .bm-t td { padding: 3px 8px; border-top: 1px solid var(--mat-sys-outline-variant); font-size: 13px; }
    .bm-t input { width: 100%; box-sizing: border-box; padding: 4px 7px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-x { border: 0; background: transparent; cursor: pointer; opacity: 0.6; }
    .bm-dim { opacity: 0.6; font-size: 13px; padding: 6px 8px; } .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
  `],
})
export class DhcpdComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();
  readonly path = DHCPD_PATH;

  loading = signal(false);
  loaded = signal(false);
  installed = signal(true);
  busy = signal(false);
  msg = signal(''); err = signal('');
  dryRun = signal(false);
  subnets = signal<Subnet[]>([]);
  hosts = signal<Host[]>([]);
  leases = signal<Lease[]>([]);
  private globals: Record<string, unknown> = {};
  private extra: unknown[] = [];

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'config', { path: DHCPD_PATH, format: 'dhcpd' }).subscribe({
      next: (resp) => {
        this.loading.set(false); this.loaded.set(true); this.installed.set(true);
        const cfg = (resp.result as { data?: { config?: { subnets?: Subnet[]; hosts?: Host[]; globals?: Record<string, unknown>; extra?: unknown[] } } })?.data?.config;
        this.subnets.set((cfg?.subnets || []).map((s) => ({ network: s.network || '', netmask: s.netmask || '', range_start: s.range_start || '', range_end: s.range_end || '', routers: s.routers || '', dns: s.dns || '' })));
        this.hosts.set((cfg?.hosts || []).map((h) => ({ name: h.name || '', mac: h.mac || '', ip: h.ip || '' })));
        this.globals = cfg?.globals || {};
        this.extra = cfg?.extra || [];
        this.loadLeases();
      },
      error: () => { this.loading.set(false); this.loaded.set(true); this.installed.set(false); },
    });
  }

  install(): void {
    this.busy.set(true); this.err.set('');
    this.agentService.callTool(this.agentId(), 'apt', { name: ['isc-dhcp-server'], state: 'present', update_cache: true }).subscribe({
      next: () => { this.busy.set(false); this.loaded.set(false); this.reload(); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'install failed'); },
    });
  }

  setSub(i: number, k: keyof Subnet, v: string): void { this.subnets.update((r) => { const c = [...r]; c[i] = { ...c[i], [k]: v }; return c; }); }
  addSub(): void { this.subnets.update((r) => [...r, { network: '', netmask: '255.255.255.0', range_start: '', range_end: '', routers: '', dns: '' }]); }
  removeSub(i: number): void { this.subnets.update((r) => r.filter((_, j) => j !== i)); }
  setHost(i: number, k: keyof Host, v: string): void { this.hosts.update((r) => { const c = [...r]; c[i] = { ...c[i], [k]: v }; return c; }); }
  addHost(): void { this.hosts.update((r) => [...r, { name: '', mac: '', ip: '' }]); }
  removeHost(i: number): void { this.hosts.update((r) => r.filter((_, j) => j !== i)); }

  save(): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const res: ConfigResource = {
      type: 'config', path: DHCPD_PATH, format: 'dhcpd',
      values: {
        globals: this.globals,
        subnets: this.subnets().filter((s) => s.network.trim() && s.netmask.trim()),
        hosts: this.hosts().filter((h) => h.name.trim()),
        extra: this.extra,
      },
    };
    this.agentService.stateApply(this.agentId(), [res], this.dryRun()).subscribe({
      next: (resp) => {
        const n = resp.plan?.changed_count ?? 0;
        if (this.dryRun()) { this.busy.set(false); this.msg.set(`Preview: ${n} change(s) — nothing written.`); return; }
        this.agentService.callTool(this.agentId(), 'systemd', { name: 'isc-dhcp-server', state: 'restarted' }).subscribe({
          next: () => { this.busy.set(false); this.msg.set(`Saved ${n} change(s) + restarted isc-dhcp-server.`); this.reload(); },
          error: () => { this.busy.set(false); this.msg.set(`Saved ${n} change(s) (server restart failed — check config).`); this.reload(); },
        });
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Save failed.'); },
    });
  }

  loadLeases(): void {
    // Parse dhcpd.leases: lease <ip> { ... hardware ethernet <mac>; ends <date>; binding state <state>; }
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', `cat ${LEASES_PATH} 2>/dev/null || true`] }).subscribe({
      next: (resp) => {
        const txt = (resp.result as { data?: { stdout?: string } })?.data?.stdout || '';
        this.leases.set(this.parseLeases(txt));
      },
      error: () => this.leases.set([]),
    });
  }

  private parseLeases(txt: string): Lease[] {
    const out: Lease[] = [];
    const re = /lease\s+([\d.]+)\s*\{([^}]*)\}/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(txt))) {
      const body = m[2];
      const mac = /hardware\s+ethernet\s+([0-9a-fA-F:]+)/.exec(body)?.[1] || '';
      const ends = /ends\s+\d+\s+([^;]+);/.exec(body)?.[1]?.trim() || '';
      const state = /binding state\s+(\w+)/.exec(body)?.[1] || '';
      if (state === 'active') out.push({ ip: m[1], mac, ends, state });
    }
    // dhcpd.leases appends; keep the last entry per IP.
    const byIp = new Map<string, Lease>();
    for (const l of out) byIp.set(l.ip, l);
    return [...byIp.values()];
  }

  deleteLease(l: Lease): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    // Stop the server, strip the lease stanza(s) for this IP, start again.
    const script = `systemctl stop isc-dhcp-server; ` +
      `python3 - "${l.ip}" <<'PY'
import re,sys
p="${LEASES_PATH}"
ip=sys.argv[1]
try:
    t=open(p).read()
except FileNotFoundError:
    sys.exit(0)
t=re.sub(r'lease\\s+'+re.escape(ip)+r'\\s*\\{[^}]*\\}\\n?','',t)
open(p,'w').write(t)
PY
systemctl start isc-dhcp-server`;
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', script] }).subscribe({
      next: () => { this.busy.set(false); this.msg.set(`Deleted lease ${l.ip}.`); this.loadLeases(); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'lease delete failed'); this.loadLeases(); },
    });
  }
}
