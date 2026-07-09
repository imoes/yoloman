import { Component, input, viewChild } from '@angular/core';
import { MatTabsModule, MatTabChangeEvent } from '@angular/material/tabs';
import { HostServicesComponent } from './host-services.component';
import { HostLogsComponent } from './host-logs.component';

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
  imports: [MatTabsModule, HostServicesComponent, HostLogsComponent],
  template: `
    <mat-tab-group animationDuration="0ms" (selectedTabChange)="onInnerTab($event)">
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
    </mat-tab-group>
  `,
  styles: [`.bm-mgmt-pane { padding: 12px 4px; }`],
})
export class HostManagementComponent {
  agentId = input.required<string>();

  private services = viewChild(HostServicesComponent);
  private logs = viewChild(HostLogsComponent);

  /** First inner tab (Services) is shown by default, so kick its load once
   * the management shell itself becomes visible; also (re)trigger per tab. */
  onInnerTab(event: MatTabChangeEvent): void {
    if (event.tab.textLabel === 'Services') this.services()?.loadOnce();
    if (event.tab.textLabel === 'Logs') this.logs()?.loadOnce();
  }

  /** Called by host-detail when the parent Management tab is opened, so the
   * default (Services) inner tab loads without needing a tab change first. */
  activate(): void {
    this.services()?.loadOnce();
  }
}
