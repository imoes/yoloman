import { Component, inject, input, signal, viewChild } from '@angular/core';
import { MatTabsModule, MatTabChangeEvent } from '@angular/material/tabs';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { AgentService } from '../../../core/services/agent.service';
import { HostServicesComponent } from './host-services.component';
import { HostLogsComponent } from './host-logs.component';
import { HostAccountsComponent } from './host-accounts.component';
import { HostStorageComponent } from './host-storage.component';
import { HostNetworkComponent } from './host-network.component';
import { HostFirewallComponent } from './host-firewall.component';
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
  imports: [MatTabsModule, MatButtonModule, MatIconModule, HostNetworkComponent, HostFirewallComponent, HostServicesComponent, HostLogsComponent, HostAccountsComponent, HostStorageComponent, HostVirtComponent],
  template: `
    <div class="bm-mgmt-bar">
      <span class="bm-mgmt-hint">Network/Storage actions need their modules on the host.</span>
      <span class="bm-spacer"></span>
      @if (syncMsg()) { <span class="bm-sync-msg">{{ syncMsg() }}</span> }
      <button mat-stroked-button (click)="enableModules()" [disabled]="syncing()">
        <mat-icon>download_for_offline</mat-icon> {{ syncing() ? 'Enabling…' : 'Enable management modules' }}
      </button>
    </div>
    <mat-tab-group animationDuration="0ms" (selectedTabChange)="onInnerTab($event)">
      <mat-tab label="Network">
        <div class="bm-mgmt-pane">
          <app-host-network [agentId]="agentId()" />
        </div>
      </mat-tab>
      <mat-tab label="Firewall">
        <div class="bm-mgmt-pane">
          <app-host-firewall [agentId]="agentId()" />
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
  styles: [`
    .bm-mgmt-pane { padding: 12px 4px; }
    .bm-mgmt-bar { display: flex; align-items: center; gap: 10px; padding: 4px 4px 10px; }
    .bm-spacer { flex: 1; }
    .bm-mgmt-hint { font-size: 12.5px; opacity: 0.6; }
    .bm-sync-msg { font-size: 12.5px; opacity: 0.8; }
  `],
})
export class HostManagementComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  syncing = signal(false);
  syncMsg = signal<string>('');

  /** The Starlark modules the Network/Storage/Firewall actions call. Pushing
   * them makes those actions executable on this host (a no-op if already present). */
  private static readonly MGMT_MODULES = [
    'community.general.nmcli', 'posix.mount', 'community.general.filesystem',
    'community.general.parted', 'posix.firewalld', 'community.general.lvg',
    'community.general.lvol',
  ];

  enableModules(): void {
    this.syncing.set(true);
    this.syncMsg.set('');
    this.agentService.syncModules(this.agentId(), HostManagementComponent.MGMT_MODULES).subscribe({
      next: (r) => {
        this.syncing.set(false);
        const failed = (r.result?.results || []).filter((x) => !x.ok).map((x) => x.fqcn);
        this.syncMsg.set(failed.length ? `pushed ${r.pushed}, failed: ${failed.join(', ')}` : `✓ ${r.result.applied} modules ready`);
      },
      error: (e) => { this.syncing.set(false); this.syncMsg.set(e?.error?.detail ?? 'push failed'); },
    });
  }

  private network = viewChild(HostNetworkComponent);
  private firewall = viewChild(HostFirewallComponent);
  private services = viewChild(HostServicesComponent);
  private logs = viewChild(HostLogsComponent);
  private accounts = viewChild(HostAccountsComponent);
  private storage = viewChild(HostStorageComponent);
  private virt = viewChild(HostVirtComponent);

  /** Lazy-load each inner tab's data when it is opened. */
  onInnerTab(event: MatTabChangeEvent): void {
    if (event.tab.textLabel === 'Network') this.network()?.loadOnce();
    if (event.tab.textLabel === 'Firewall') this.firewall()?.loadOnce();
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
