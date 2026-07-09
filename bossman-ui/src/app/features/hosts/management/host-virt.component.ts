import { Component, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';
import { VirtResponse } from '../../../core/models/agent.model';

/** Virtualization section: which hypervisor stack(s) the host runs (Proxmox /
 * libvirt) and their guests, from virt_facts. Per-guest start/stop go through
 * the fleet tool router (qm / virsh). Non-hypervisor hosts show "none". */
@Component({
  selector: 'app-host-virt',
  standalone: true,
  imports: [MatButtonModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-mgmt-section">
      <div class="bm-mgmt-toolbar">
        <button mat-stroked-button (click)="reload()" [disabled]="loading()">Reload</button>
        <label class="bm-chk"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
        @if (data(); as v) { <span class="bm-mgmt-count">hypervisors: {{ v.hypervisors.length ? v.hypervisors.join(', ') : 'none' }}</span> }
        @if (msg()) { <span class="bm-svc-ok">{{ msg() }}</span> }
        @if (err()) { <span class="bm-svc-err">{{ err() }}</span> }
      </div>

      @if (loading()) {
        <div class="bm-mgmt-loading"><mat-spinner diameter="28" /></div>
      } @else if (loadErr()) {
        <p class="bm-svc-err">{{ loadErr() }}</p>
      } @else if (data(); as v) {
        @if (!v.hypervisors.length) {
          <p class="bm-empty">No local virtualization stack detected on this host.</p>
        }

        @if (v.proxmox.available) {
          <h4>Proxmox VE — VMs</h4>
          <table class="bm-mgmt-table"><thead><tr><th>VMID</th><th>Name</th><th>Status</th><th class="bm-mgmt-actions">Actions</th></tr></thead><tbody>
            @for (vm of v.proxmox.vms || []; track vm.vmid) {
              <tr>
                <td class="bm-mgmt-unit">{{ vm.vmid }}</td><td>{{ vm.name }}</td>
                <td [class.bm-active]="vm.status === 'running'">{{ vm.status }}</td>
                <td class="bm-mgmt-actions">
                  <button mat-button (click)="qm(vm.vmid, 'started')" [disabled]="busy()">Start</button>
                  <button mat-button (click)="qm(vm.vmid, 'shutdown')" [disabled]="busy()">Shutdown</button>
                  <button mat-button (click)="qm(vm.vmid, 'stopped')" [disabled]="busy()">Stop</button>
                  <button mat-button (click)="qm(vm.vmid, 'rebooted')" [disabled]="busy()">Reboot</button>
                </td>
              </tr>
            }
          </tbody></table>
          @if ((v.proxmox.containers || []).length) {
            <h4>Proxmox VE — LXC</h4>
            <table class="bm-mgmt-table"><thead><tr><th>VMID</th><th>Name</th><th>Status</th></tr></thead><tbody>
              @for (ct of v.proxmox.containers || []; track ct.vmid) { <tr><td class="bm-mgmt-unit">{{ ct.vmid }}</td><td>{{ ct.name }}</td><td>{{ ct.status }}</td></tr> }
            </tbody></table>
          }
          <div class="bm-acct-new">
            <input type="text" placeholder="vmid" [value]="pxId()" (input)="pxId.set($any($event.target).value)" />
            <input type="text" placeholder="snapshot name" [value]="pxSnap()" (input)="pxSnap.set($any($event.target).value)" />
            <button mat-button (click)="qmSnapshot()" [disabled]="busy() || !pxId().trim() || !pxSnap().trim()">Snapshot</button>
            <input type="text" placeholder="migrate to node" [value]="pxTarget()" (input)="pxTarget.set($any($event.target).value)" />
            <button mat-button (click)="qmMigrate()" [disabled]="busy() || !pxId().trim() || !pxTarget().trim()">Migrate</button>
          </div>
        }

        @if (v.libvirt.available) {
          <h4>libvirt / KVM — domains</h4>
          <table class="bm-mgmt-table"><thead><tr><th>Name</th><th>State</th><th class="bm-mgmt-actions">Actions</th></tr></thead><tbody>
            @for (d of v.libvirt.domains || []; track d.name) {
              <tr>
                <td class="bm-mgmt-unit">{{ d.name }}</td>
                <td [class.bm-active]="d.state === 'running'">{{ d.state }}</td>
                <td class="bm-mgmt-actions">
                  <button mat-button (click)="virsh(d.name, 'started')" [disabled]="busy()">Start</button>
                  <button mat-button (click)="virsh(d.name, 'shutdown')" [disabled]="busy()">Shutdown</button>
                  <button mat-button (click)="virsh(d.name, 'stopped')" [disabled]="busy()">Destroy</button>
                  <button mat-button (click)="virsh(d.name, 'rebooted')" [disabled]="busy()">Reboot</button>
                </td>
              </tr>
            }
          </tbody></table>
          <div class="bm-acct-new">
            <input type="text" placeholder="domain" [value]="lvDomain()" (input)="lvDomain.set($any($event.target).value)" />
            <input type="text" placeholder="snapshot name" [value]="lvSnap()" (input)="lvSnap.set($any($event.target).value)" />
            <button mat-button (click)="virshSnapshot()" [disabled]="busy() || !lvDomain().trim() || !lvSnap().trim()">Snapshot</button>
            <input type="text" placeholder="dest URI (qemu+ssh://node2/system)" [value]="lvDest()" (input)="lvDest.set($any($event.target).value)" />
            <button mat-button (click)="virshMigrate()" [disabled]="busy() || !lvDomain().trim() || !lvDest().trim()">Migrate</button>
          </div>
        }
      }
    </div>
  `,
  styles: [
    `
      .bm-mgmt-section { padding: 8px 0; }
      .bm-mgmt-toolbar { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; flex-wrap: wrap; }
      .bm-mgmt-count { color: var(--bm-muted, #888); font-size: 12px; }
      .bm-mgmt-loading { display: flex; justify-content: center; padding: 24px; }
      h4 { margin: 16px 0 6px; }
      .bm-mgmt-table { width: 100%; border-collapse: collapse; font-size: 13px; margin-bottom: 6px; }
      .bm-mgmt-table th, .bm-mgmt-table td { text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--bm-border, #eee); }
      .bm-mgmt-unit { font-family: monospace; }
      .bm-mgmt-actions { white-space: nowrap; }
      .bm-active { color: #2e7d32; }
      .bm-empty { color: var(--bm-muted, #888); }
      .bm-chk { font-size: 12px; color: var(--bm-muted, #888); display: flex; align-items: center; gap: 4px; }
      .bm-acct-new { display: flex; gap: 8px; margin: 6px 0 12px; flex-wrap: wrap; align-items: center; }
      .bm-acct-new input { padding: 6px 8px; border: 1px solid var(--bm-border, #ccc); border-radius: 4px; }
      .bm-svc-ok { color: #2e7d32; font-size: 12px; }
      .bm-svc-err { color: #c62828; font-size: 12px; }
    `,
  ],
})
export class HostVirtComponent {
  private agentService = inject(AgentService);

  agentId = input.required<string>();

  data = signal<VirtResponse | null>(null);
  loading = signal(false);
  loaded = signal(false);
  loadErr = signal<string | null>(null);
  busy = signal(false);
  msg = signal<string | null>(null);
  err = signal<string | null>(null);

  dryRun = signal(true);
  pxId = signal('');
  pxSnap = signal('');
  pxTarget = signal('');
  lvDomain = signal('');
  lvSnap = signal('');
  lvDest = signal('');

  loadOnce(): void {
    if (this.loaded() || this.loading()) return;
    this.reload();
  }

  reload(): void {
    this.loading.set(true);
    this.loadErr.set(null);
    this.agentService.virt(this.agentId()).subscribe({
      next: (res) => {
        this.data.set(res);
        this.loading.set(false);
        this.loaded.set(true);
      },
      error: (e) => {
        this.loading.set(false);
        this.loaded.set(true);
        this.loadErr.set(e?.error?.detail ?? 'failed to load virtualization');
      },
    });
  }

  private control(tool: string, params: Record<string, unknown>, label: string): void {
    this.busy.set(true);
    this.msg.set(null);
    this.err.set(null);
    this.agentService.callTool(this.agentId(), tool, params).subscribe({
      next: (res) => {
        this.busy.set(false);
        const r = res.result as { changed?: boolean; msg?: string } | undefined;
        this.msg.set(`${label}: ${r?.msg ?? 'ok'}${r?.changed === false ? ' (no change)' : ''}`);
        this.reload();
      },
      error: (e) => {
        this.busy.set(false);
        this.err.set(e?.error?.detail ?? `${label} failed`);
      },
    });
  }

  // Power actions map to qm/virsh subcommands via the generic command+args
  // interface; they run immediately (not dry-run).
  private static QM_POWER: Record<string, string> = { started: 'start', stopped: 'stop', shutdown: 'shutdown', rebooted: 'reboot' };
  private static VIRSH_POWER: Record<string, string> = { started: 'start', stopped: 'destroy', shutdown: 'shutdown', rebooted: 'reboot' };

  qm(vmid: string, state: string): void {
    const sub = HostVirtComponent.QM_POWER[state];
    this.control('qm', { command: sub, args: [vmid] }, `qm ${sub} ${vmid}`);
  }

  virsh(domain: string, state: string): void {
    const sub = HostVirtComponent.VIRSH_POWER[state];
    this.control('virsh', { command: sub, args: [domain] }, `virsh ${sub} ${domain}`);
  }

  qmSnapshot(): void {
    this.control('qm', { command: 'snapshot', args: [this.pxId().trim(), this.pxSnap().trim()], dry_run: this.dryRun() }, `qm snapshot ${this.pxId().trim()}`);
  }

  qmMigrate(): void {
    this.control('qm', { command: 'migrate', args: [this.pxId().trim(), this.pxTarget().trim(), '--online'], dry_run: this.dryRun() }, `qm migrate ${this.pxId().trim()}`);
  }

  virshSnapshot(): void {
    this.control('virsh', { command: 'snapshot-create-as', args: [this.lvDomain().trim(), this.lvSnap().trim()], dry_run: this.dryRun() }, `virsh snapshot ${this.lvDomain().trim()}`);
  }

  virshMigrate(): void {
    this.control('virsh', { command: 'migrate', args: ['--live', this.lvDomain().trim(), this.lvDest().trim()], dry_run: this.dryRun() }, `virsh migrate ${this.lvDomain().trim()}`);
  }
}
