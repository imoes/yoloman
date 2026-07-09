import { Component, input, viewChild } from '@angular/core';
import { MatTabsModule, MatTabChangeEvent } from '@angular/material/tabs';
import { HostServicesComponent } from './host-services.component';
import { HostLogsComponent } from './host-logs.component';
import { HostAccountsComponent } from './host-accounts.component';
import { HostStorageComponent } from './host-storage.component';
import { HostNetworkComponent } from './host-network.component';
import { HostVirtComponent } from './host-virt.component';

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
  imports: [MatTabsModule, HostNetworkComponent, HostServicesComponent, HostLogsComponent, HostAccountsComponent, HostStorageComponent, HostVirtComponent],
  template: `
    <mat-tab-group animationDuration="0ms" (selectedTabChange)="onInnerTab($event)">
      <mat-tab label="Network">
        <div class="bm-mgmt-pane">
          <app-host-network [agentId]="agentId()" />
        </div>
      </mat-tab>
      <mat-tab label="Services">
        <div class="bm-mgmt-pane">
          <app-host-services [agentId]="agentId()" />
        </div>
      </mat-tab>
      <mat-tab label="Logs">
        <div class="bm-mgmt-pane">
          <app-host-logs [agentId]="agentId()" />
        </div>
      </mat-tab>
      <mat-tab label="Accounts">
        <div class="bm-mgmt-pane">
          <app-host-accounts [agentId]="agentId()" />
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
  styles: [`.bm-mgmt-pane { padding: 12px 4px; }`],
})
export class HostManagementComponent {
  agentId = input.required<string>();

  private network = viewChild(HostNetworkComponent);
  private services = viewChild(HostServicesComponent);
  private logs = viewChild(HostLogsComponent);
  private accounts = viewChild(HostAccountsComponent);
  private storage = viewChild(HostStorageComponent);
  private virt = viewChild(HostVirtComponent);

  /** Lazy-load each inner tab's data when it is opened. */
  onInnerTab(event: MatTabChangeEvent): void {
    if (event.tab.textLabel === 'Network') this.network()?.loadOnce();
    if (event.tab.textLabel === 'Services') this.services()?.loadOnce();
    if (event.tab.textLabel === 'Logs') this.logs()?.loadOnce();
    if (event.tab.textLabel === 'Accounts') this.accounts()?.loadOnce();
    if (event.tab.textLabel === 'Storage') this.storage()?.loadOnce();
    if (event.tab.textLabel === 'Virtualization') this.virt()?.loadOnce();
  }

  /** Called by host-detail when the parent Management tab is opened, so the
   * default (Network) inner tab loads without needing a tab change first. */
  activate(): void {
    this.network()?.loadOnce();
  }
}
