import { Component, inject, input, signal, viewChild } from '@angular/core';
import { MatTabsModule, MatTabChangeEvent } from '@angular/material/tabs';
import { AgentService } from '../../../core/services/agent.service';
import { HostServicesComponent } from './host-services.component';
import { HostLogsComponent } from './host-logs.component';
import { HostAccountsComponent } from './host-accounts.component';
import { HostStorageComponent } from './host-storage.component';
import { HostNetworkComponent } from './host-network.component';
import { HostFirewallComponent } from './host-firewall.component';
import { HostFreeipaComponent } from './host-freeipa.component';
import { HostVirtComponent } from './host-virt.component';
import { HostUpdatesComponent } from './host-updates.component';
import { HostLogfilesComponent } from './host-logfiles.component';

/** Block J4 — the Cockpit-like per-host management shell. Sits under one
 * "Management" tab of host-detail and holds an inner tab-group with one child
 * component per domain (Services, Logs, Accounts, Storage, Network). Each
 * child fetches its own live data lazily when its inner tab is first opened
 * (Cockpit-style: nothing is pulled until you look at it). Sub-blocks add
 * their tab here as they land; J4a ships Services first.
 */
@Component({
  selector: 'app-host-management',
  standalone: true,
  imports: [MatTabsModule, HostNetworkComponent, HostFirewallComponent, HostServicesComponent, HostLogsComponent, HostLogfilesComponent, HostAccountsComponent, HostStorageComponent, HostFreeipaComponent, HostVirtComponent, HostUpdatesComponent],
  template: `
    <mat-tab-group animationDuration="0ms" (selectedTabChange)="onInnerTab($event)">
      <mat-tab label="Network">
        <div class="bm-mgmt-pane">
          <app-host-network [agentId]="agentId()" />
        </div>
      </mat-tab>
      @if (firewallAvailable()) {
        <mat-tab label="Firewall">
          <div class="bm-mgmt-pane">
            <app-host-firewall [agentId]="agentId()" />
          </div>
        </mat-tab>
      }
      <mat-tab label="Services">
        <div class="bm-mgmt-pane">
          <app-host-services [agentId]="agentId()" />
        </div>
      </mat-tab>
      <mat-tab label="Updates">
        <div class="bm-mgmt-pane">
          <app-host-updates [agentId]="agentId()" />
        </div>
      </mat-tab>
      <mat-tab label="Logs">
        <div class="bm-mgmt-pane">
          <app-host-logs [agentId]="agentId()" />
        </div>
      </mat-tab>
      <mat-tab label="Log files">
        <div class="bm-mgmt-pane">
          <app-host-logfiles [agentId]="agentId()" />
        </div>
      </mat-tab>
      <mat-tab label="Accounts">
        <div class="bm-mgmt-pane">
          <app-host-accounts [agentId]="agentId()" />
        </div>
      </mat-tab>
      <mat-tab label="FreeIPA">
        <div class="bm-mgmt-pane">
          <app-host-freeipa [agentId]="agentId()" />
        </div>
      </mat-tab>
      <mat-tab label="Storage">
        <div class="bm-mgmt-pane">
          <app-host-storage [agentId]="agentId()" />
        </div>
      </mat-tab>
      <mat-tab label="Virtualization">
        <div class="bm-mgmt-pane">
          <app-host-virt [agentId]="agentId()" />
        </div>
      </mat-tab>
    </mat-tab-group>
  `,
  styles: [`
    .bm-mgmt-pane { padding: 12px 4px; }
  `],
})
export class HostManagementComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  // The Firewall tab is only shown when firewalld's CLI exists on the host.
  firewallAvailable = signal(true);
  private firewallProbed = false;
  private modulesSynced = false;

  private probeFirewall(): void {
    if (this.firewallProbed) return;
    this.firewallProbed = true;
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', 'command -v firewall-cmd'] }).subscribe({
      next: (res) => {
        const d = (res.result as { data?: { rc?: number; stdout?: string } })?.data;
        this.firewallAvailable.set((d?.rc ?? 1) === 0 && !!(d?.stdout || '').trim());
      },
      error: () => this.firewallAvailable.set(false),
    });
  }

  /** The Starlark modules the Network/Storage/Firewall actions call. They are
   * pushed automatically when the Management tab is opened (idempotent, a no-op
   * if already present) — no manual "enable" step. Includes ZFS (zpool + zfs
   * dataset) alongside LVM/VDO. */
  private static readonly MGMT_MODULES = [
    'community.general.nmcli', 'posix.mount', 'community.general.filesystem',
    'community.general.parted', 'posix.firewalld', 'community.general.lvg',
    'community.general.lvol', 'community.general.vdo', 'community.general.zfs',
  ];

  /** Push the management module set once per view, silently. */
  private ensureModules(): void {
    if (this.modulesSynced) return;
    this.modulesSynced = true;
    this.agentService.syncModules(this.agentId(), HostManagementComponent.MGMT_MODULES).subscribe({ next: () => {}, error: () => {} });
  }

  private network = viewChild(HostNetworkComponent);
  private firewall = viewChild(HostFirewallComponent);
  private services = viewChild(HostServicesComponent);
  private updates = viewChild(HostUpdatesComponent);
  private logs = viewChild(HostLogsComponent);
  private logfiles = viewChild(HostLogfilesComponent);
  private accounts = viewChild(HostAccountsComponent);
  private freeipa = viewChild(HostFreeipaComponent);
  private storage = viewChild(HostStorageComponent);
  private virt = viewChild(HostVirtComponent);

  /** Lazy-load each inner tab's data when it is opened. */
  onInnerTab(event: MatTabChangeEvent): void {
    if (event.tab.textLabel === 'Network') this.network()?.loadOnce();
    if (event.tab.textLabel === 'Firewall') this.firewall()?.loadOnce();
    if (event.tab.textLabel === 'Services') this.services()?.loadOnce();
    if (event.tab.textLabel === 'Updates') this.updates()?.loadOnce();
    if (event.tab.textLabel === 'Logs') this.logs()?.loadOnce();
    if (event.tab.textLabel === 'Log files') this.logfiles()?.loadOnce();
    if (event.tab.textLabel === 'Accounts') this.accounts()?.loadOnce();
    if (event.tab.textLabel === 'FreeIPA') this.freeipa()?.loadOnce();
    if (event.tab.textLabel === 'Storage') this.storage()?.loadOnce();
    if (event.tab.textLabel === 'Virtualization') this.virt()?.loadOnce();
  }

  /** Called by host-detail when the parent Management tab is opened, so the
   * default (Network) inner tab loads without needing a tab change first. */
  activate(): void {
    this.network()?.loadOnce();
    this.probeFirewall();
    this.ensureModules();
  }
}
