import { Component, computed, input } from '@angular/core';
import { DatePipe } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { Agent, InventoryFacts } from '../../core/models/agent.model';

/** The CheckMK-style HW/SW inventory view (Block H3): the agent's facts
 * document (internal/inventory) rendered as Hardware / Software sections
 * with key-value tables plus Disks/NICs tables — the answer to "Die
 * Facts sind unvollständig: es fehlt CPU-Typ, Mainboard, Seriennummer". */
@Component({
  selector: 'app-host-inventory',
  standalone: true,
  imports: [DatePipe, MatCardModule],
  template: `
    @if (hasFacts()) {
      <div class="bm-inv-grid">
        <mat-card class="bm-inv-card">
          <h3>System</h3>
          <dl>
            @for (row of systemRows(); track row[0]) {
              <dt>{{ row[0] }}</dt>
              <dd>{{ row[1] }}</dd>
            }
          </dl>
        </mat-card>

        <mat-card class="bm-inv-card">
          <h3>Processor</h3>
          <dl>
            @for (row of cpuRows(); track row[0]) {
              <dt>{{ row[0] }}</dt>
              <dd>{{ row[1] }}</dd>
            }
          </dl>
        </mat-card>

        <mat-card class="bm-inv-card">
          <h3>Mainboard &amp; BIOS</h3>
          <dl>
            @for (row of boardRows(); track row[0]) {
              <dt>{{ row[0] }}</dt>
              <dd>{{ row[1] }}</dd>
            }
          </dl>
        </mat-card>

        <mat-card class="bm-inv-card">
          <h3>Operating system</h3>
          <dl>
            @for (row of osRows(); track row[0]) {
              <dt>{{ row[0] }}</dt>
              <dd>{{ row[1] }}</dd>
            }
          </dl>
        </mat-card>
      </div>

      @if (facts().disks?.length) {
        <mat-card class="bm-inv-card bm-inv-wide">
          <h3>Disks</h3>
          <table class="bm-inv-table">
            <thead>
              <tr><th>Device</th><th>Size</th><th>Model</th><th>Serial</th><th>Type</th></tr>
            </thead>
            <tbody>
              @for (d of facts().disks; track d.name) {
                <tr>
                  <td class="bm-mono">{{ d.name }}</td>
                  <td>{{ formatBytes(d.size_bytes) }}</td>
                  <td>{{ d.model || '—' }}</td>
                  <td class="bm-mono">{{ d.serial || '—' }}</td>
                  <td>{{ d.rotational ? 'HDD' : 'SSD/Flash' }}</td>
                </tr>
              }
            </tbody>
          </table>
        </mat-card>
      }

      @if (facts().nics?.length) {
        <mat-card class="bm-inv-card bm-inv-wide">
          <h3>Network interfaces</h3>
          <table class="bm-inv-table">
            <thead>
              <tr><th>Interface</th><th>Address</th><th>MAC</th><th>State</th><th>MTU</th><th>Speed</th></tr>
            </thead>
            <tbody>
              @for (n of facts().nics; track n.name) {
                <tr>
                  <td class="bm-mono">{{ n.name }}</td>
                  <td class="bm-mono">{{ nicAddresses(n) }}</td>
                  <td class="bm-mono">{{ n.mac || '—' }}</td>
                  <td>
                    <span class="bm-dot" [class.bm-dot--up]="nicUp(n)"></span>
                    {{ nicState(n) }}
                  </td>
                  <td>{{ n.mtu ?? '—' }}</td>
                  <td>{{ n.speed_mbps ? n.speed_mbps + ' Mbit/s' : (nicUp(n) ? 'virtual' : '—') }}</td>
                </tr>
              }
            </tbody>
          </table>
        </mat-card>
      }

      <p class="bm-inv-footer">
        Inventory collected {{ facts().collected_at | date: 'medium' }}
        @if (agent().facts_updated_at) {
          · last change {{ agent().facts_updated_at | date: 'medium' }}
        }
      </p>
    } @else {
      <p class="bm-empty">
        No inventory yet — it arrives with the first poll after the agent (with inventory support)
        reports in.
      </p>
    }
  `,
  styles: [
    `
      .bm-inv-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
        gap: 12px;
      }
      .bm-inv-card {
        padding: 16px;
      }
      .bm-inv-wide {
        margin-top: 12px;
      }
      .bm-inv-card h3 {
        margin: 0 0 10px;
        font-size: 12px;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        opacity: 0.7;
        border-bottom: 2px solid var(--bm-green);
        display: inline-block;
        padding-bottom: 2px;
      }
      dl {
        display: grid;
        grid-template-columns: 150px 1fr;
        row-gap: 6px;
        margin: 0;
      }
      dt {
        opacity: 0.65;
        font-size: 13px;
      }
      dd {
        margin: 0;
        font-size: 13px;
        overflow-wrap: anywhere;
      }
      .bm-inv-table {
        width: 100%;
        border-collapse: collapse;
        font-size: 13px;
      }
      .bm-inv-table th {
        text-align: left;
        font-size: 11px;
        opacity: 0.6;
        padding: 4px 8px;
      }
      .bm-inv-table td {
        padding: 6px 8px;
        border-top: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 60%, transparent);
      }
      .bm-mono {
        font-family: monospace;
        font-size: 12.5px;
      }
      .bm-dot {
        display: inline-block;
        width: 8px;
        height: 8px;
        border-radius: 50%;
        background: var(--bm-unknown);
        margin-right: 4px;
      }
      .bm-dot--up {
        background: var(--bm-green);
      }
      .bm-inv-footer {
        margin-top: 14px;
        font-size: 12px;
        opacity: 0.6;
      }
      .bm-empty {
        opacity: 0.6;
      }
    `,
  ],
})
export class HostInventoryComponent {
  agent = input.required<Agent>();

  facts = computed<InventoryFacts>(() => this.agent().facts ?? {});
  hasFacts = computed(() => Object.keys(this.facts()).length > 0);

  systemRows = computed(() => {
    const s = this.facts().system ?? {};
    return this.rows([
      ['Manufacturer', s.manufacturer],
      ['Product', s.product_name],
      ['Serial number', s.serial_number],
      ['UUID', s.uuid],
      ['Chassis', s.chassis_type],
      ['Virtualization', s.virtualization],
      ['Family', s.family],
    ]);
  });

  cpuRows = computed(() => {
    const c = this.facts().cpu ?? {};
    const topology =
      c.sockets || c.cores || c.threads
        ? `${c.sockets ?? '?'} socket(s) · ${c.cores ?? '?'} core(s) · ${c.threads ?? '?'} thread(s)`
        : undefined;
    return this.rows([
      ['Model', c.model],
      ['Vendor', c.vendor],
      ['Topology', topology],
      ['Clock', c.mhz ? c.mhz + ' MHz' : undefined],
      ['Cache', c.cache],
      ['Architecture', c.architecture],
      ['Memory', this.facts().memory_mb ? this.formatMB(this.facts().memory_mb!) : undefined],
    ]);
  });

  boardRows = computed(() => {
    const b = this.facts().board ?? {};
    const bios = this.facts().bios ?? {};
    return this.rows([
      ['Board vendor', b.vendor],
      ['Board name', b.name],
      ['Board serial', b.serial],
      ['Board version', b.version],
      ['BIOS vendor', bios.vendor],
      ['BIOS version', bios.version],
      ['BIOS date', bios.date],
    ]);
  });

  osRows = computed(() => {
    const o = this.facts().os ?? {};
    return this.rows([
      ['Distribution', o.pretty_name || o.distribution],
      ['Version', o.version],
      ['Codename', o.codename],
      ['Kernel', o.kernel],
      ['Hostname', o.hostname],
      // The resolvable DNS name, so a satellite (no direct address) still
      // shows one — falls back to the inventory hostname server-side.
      ['DNS name', this.agent().dns_name ?? undefined],
    ]);
  });

  private rows(pairs: [string, string | undefined][]): [string, string][] {
    return pairs.filter((p): p is [string, string] => !!p[1]);
  }

  /** Joined IPv4+IPv6 addresses of one NIC, or "—" when the agent's
   * inventory doesn't report addresses (older agents omit them). */
  nicAddresses(n: { ipv4?: string[]; ipv6?: string[] }): string {
    const addrs = [...(n.ipv4 ?? []), ...(n.ipv6 ?? [])];
    return addrs.length ? addrs.join(', ') : '—';
  }

  /** virtio/virtual NICs (e.g. Proxmox ens18) report operstate "unknown" even
   * when they are fully up — the kernel driver doesn't implement carrier
   * detection. Treat "unknown" with real addresses as up, so a working NIC
   * doesn't read as an error. */
  nicUp(n: { state?: string; ipv4?: string[]; ipv6?: string[] }): boolean {
    const s = (n.state || '').toLowerCase();
    if (s === 'up') return true;
    if (s === 'unknown' && [...(n.ipv4 ?? []), ...(n.ipv6 ?? [])].length) return true;
    return false;
  }
  nicState(n: { state?: string; ipv4?: string[]; ipv6?: string[] }): string {
    if (this.nicUp(n)) return 'up';
    return n.state || '—';
  }

  formatBytes(bytes?: number): string {
    if (!bytes) return '—';
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    let v = bytes;
    let i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return `${v.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
  }

  private formatMB(mb: number): string {
    return mb >= 1024 ? (mb / 1024).toFixed(1) + ' GiB' : mb + ' MiB';
  }
}
