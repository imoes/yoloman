import { Component, computed, inject, input, signal, viewChild } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
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
import { RolesFeaturesComponent } from './roles/roles-features.component';

interface SnapIn { id: string; label: string; icon: string; category: string; }

/** Block J4 / MMC — the per-host management console, styled like a Microsoft
 * Management Console: a console tree of snap-ins (left), the selected snap-in's
 * detail (center), and an Actions pane (right). Each snap-in is one of the
 * existing standalone domain panels (unchanged) plus the new Roles & Features
 * snap-in (install/configure packages). Panels load lazily on first selection
 * and stay alive after (shown/hidden), mirroring the old tab behaviour.
 */
@Component({
  selector: 'app-host-management',
  standalone: true,
  imports: [
    MatIconModule, MatButtonModule,
    HostNetworkComponent, HostFirewallComponent, HostServicesComponent, HostUpdatesComponent,
    HostLogsComponent, HostAccountsComponent, HostFreeipaComponent, HostStorageComponent,
    HostVirtComponent, RolesFeaturesComponent,
  ],
  template: `
    <div class="bm-mmc" [class.bm-mmc--noactions]="!actionsOpen()">
      <!-- Console tree -->
      <aside class="bm-mmc-tree">
        @for (grp of tree(); track grp.category) {
          <div class="bm-mmc-cat">{{ grp.category }}</div>
          @for (s of grp.items; track s.id) {
            <button type="button" class="bm-mmc-node" [class.bm-mmc-sel]="selected() === s.id" (click)="select(s.id)">
              <mat-icon>{{ s.icon }}</mat-icon><span>{{ s.label }}</span>
            </button>
          }
        }
      </aside>

      <!-- Detail (selected snap-in) — panels instantiate on first open, stay alive -->
      <section class="bm-mmc-detail">
        @if (visited().has('roles')) { <div [style.display]="show('roles')"><app-roles-features [agentId]="agentId()" /></div> }
        @if (visited().has('services')) { <div [style.display]="show('services')"><app-host-services [agentId]="agentId()" /></div> }
        @if (visited().has('updates')) { <div [style.display]="show('updates')"><app-host-updates [agentId]="agentId()" /></div> }
        @if (visited().has('logs')) { <div [style.display]="show('logs')"><app-host-logs [agentId]="agentId()" /></div> }
        @if (visited().has('accounts')) { <div [style.display]="show('accounts')"><app-host-accounts [agentId]="agentId()" /></div> }
        @if (visited().has('network')) { <div [style.display]="show('network')"><app-host-network [agentId]="agentId()" /></div> }
        @if (visited().has('firewall')) { <div [style.display]="show('firewall')"><app-host-firewall [agentId]="agentId()" /></div> }
        @if (visited().has('storage')) { <div [style.display]="show('storage')"><app-host-storage [agentId]="agentId()" /></div> }
        @if (visited().has('freeipa')) { <div [style.display]="show('freeipa')"><app-host-freeipa [agentId]="agentId()" /></div> }
        @if (visited().has('virt')) { <div [style.display]="show('virt')"><app-host-virt [agentId]="agentId()" /></div> }
      </section>

      <!-- Actions pane -->
      <aside class="bm-mmc-actions">
        <div class="bm-mmc-ah">
          <span>Actions</span>
          <button type="button" class="bm-mmc-collapse" (click)="actionsOpen.set(!actionsOpen())" title="Toggle actions">
            <mat-icon>{{ actionsOpen() ? 'chevron_right' : 'chevron_left' }}</mat-icon>
          </button>
        </div>
        <div class="bm-mmc-asub">{{ selectedLabel() }}</div>
        <button mat-stroked-button class="bm-mmc-action" (click)="refreshSelected()"><mat-icon>refresh</mat-icon> Refresh</button>
        @if (selected() === 'roles') {
          <button mat-stroked-button class="bm-mmc-action" (click)="roles()?.openWizard()"><mat-icon>add</mat-icon> Add roles and features</button>
        }
      </aside>
    </div>
  `,
  styles: [`
    .bm-mmc { display: grid; grid-template-columns: 280px 1fr 240px; gap: 16px; align-items: start; }
    .bm-mmc--noactions { grid-template-columns: 280px 1fr; }
    .bm-mmc-tree, .bm-mmc-detail, .bm-mmc-actions {
      border: 1px solid var(--mat-sys-outline-variant); border-radius: 12px;
      background: var(--mat-sys-surface-container-low, rgba(127,127,127,0.04));
    }
    .bm-mmc-tree { padding: 8px 6px; min-height: 420px; }
    .bm-mmc-detail { padding: 14px 16px; min-width: 0; min-height: 420px; }
    .bm-mmc-actions { padding: 12px 12px; }
    .bm-mmc--noactions .bm-mmc-actions { position: relative; }
    .bm-mmc-cat { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; opacity: 0.55; padding: 10px 10px 4px; }
    .bm-mmc-node {
      display: flex; align-items: center; gap: 8px; width: 100%; text-align: left;
      background: none; border: none; border-left: 3px solid transparent; color: inherit;
      padding: 7px 10px; cursor: pointer; font-size: 13.5px; border-radius: 0 6px 6px 0;
    }
    .bm-mmc-node:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-mmc-node mat-icon { font-size: 18px; width: 18px; height: 18px; opacity: 0.8; }
    .bm-mmc-sel { border-left-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); font-weight: 600; }
    .bm-mmc-ah { display: flex; align-items: center; justify-content: space-between; font-weight: 700; padding-bottom: 6px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-mmc-collapse { background: none; border: none; color: inherit; cursor: pointer; opacity: 0.7; }
    .bm-mmc-asub { font-size: 12px; opacity: 0.6; margin: 8px 0; }
    .bm-mmc-action { width: 100%; justify-content: flex-start; margin-bottom: 6px; }
    @media (max-width: 1280px) { .bm-mmc { grid-template-columns: 240px 1fr; } .bm-mmc-actions { display: none; } }
  `],
})
export class HostManagementComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  firewallAvailable = signal(true);
  actionsOpen = signal(true);
  selected = signal<string>('network');
  visited = signal<Set<string>>(new Set());

  private firewallProbed = false;
  private modulesSynced = false;

  private readonly snapins: SnapIn[] = [
    { id: 'roles', label: 'Roles & Features', icon: 'widgets', category: 'Server' },
    { id: 'services', label: 'Services', icon: 'settings_applications', category: 'Server' },
    { id: 'updates', label: 'Updates', icon: 'system_update_alt', category: 'Server' },
    { id: 'logs', label: 'Logs', icon: 'article', category: 'Server' },
    { id: 'accounts', label: 'Accounts', icon: 'group', category: 'Server' },
    { id: 'network', label: 'Network', icon: 'lan', category: 'Network' },
    { id: 'firewall', label: 'Firewall', icon: 'security', category: 'Network' },
    { id: 'storage', label: 'Storage', icon: 'storage', category: 'Storage' },
    { id: 'freeipa', label: 'FreeIPA', icon: 'badge', category: 'Identity' },
    { id: 'virt', label: 'Virtualization', icon: 'dns', category: 'Virtualization' },
  ];

  tree = computed(() => {
    const groups = new Map<string, SnapIn[]>();
    for (const s of this.snapins) {
      if (s.id === 'firewall' && !this.firewallAvailable()) continue;
      (groups.get(s.category) ?? groups.set(s.category, []).get(s.category)!).push(s);
    }
    return [...groups.entries()].map(([category, items]) => ({ category, items }));
  });

  selectedLabel = computed(() => this.snapins.find((s) => s.id === this.selected())?.label ?? '');
  show(id: string): string { return this.selected() === id ? 'block' : 'none'; }

  roles = viewChild(RolesFeaturesComponent);
  private network = viewChild(HostNetworkComponent);
  private firewall = viewChild(HostFirewallComponent);
  private services = viewChild(HostServicesComponent);
  private updates = viewChild(HostUpdatesComponent);
  private logs = viewChild(HostLogsComponent);
  private accounts = viewChild(HostAccountsComponent);
  private freeipa = viewChild(HostFreeipaComponent);
  private storage = viewChild(HostStorageComponent);
  private virt = viewChild(HostVirtComponent);

  /** Load-on-first-open per snap-in (mirrors the old lazy tabs). The panel is
   * created by the @if this tick, so its data load runs on the next tick. */
  private loadFor(id: string): void {
    setTimeout(() => {
      switch (id) {
        case 'services': this.services()?.loadOnce(); break;
        case 'updates': this.updates()?.loadOnce(); break;
        case 'logs': this.logs()?.loadOnce(); break;
        case 'accounts': this.accounts()?.loadOnce(); break;
        case 'network': this.network()?.loadOnce(); break;
        case 'firewall': this.firewall()?.loadOnce(); break;
        case 'storage': this.storage()?.loadOnce(); break;
        case 'freeipa': this.freeipa()?.loadOnce(); break;
        case 'virt': this.virt()?.loadOnce(); break;
        // 'roles' loads itself on init.
      }
    }, 0);
  }

  select(id: string): void {
    this.selected.set(id);
    if (!this.visited().has(id)) {
      this.visited.update((v) => new Set(v).add(id));
      this.loadFor(id);
    }
  }

  refreshSelected(): void {
    const id = this.selected();
    if (id === 'roles') { this.roles()?.reload(); return; }
    this.loadFor(id);
  }

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

  private static readonly MGMT_MODULES = [
    'community.general.nmcli', 'posix.mount', 'community.general.filesystem',
    'community.general.parted', 'posix.firewalld', 'community.general.lvg',
    'community.general.lvol', 'community.general.vdo', 'community.general.zfs',
  ];

  private ensureModules(): void {
    if (this.modulesSynced) return;
    this.modulesSynced = true;
    this.agentService.syncModules(this.agentId(), HostManagementComponent.MGMT_MODULES).subscribe({ next: () => {}, error: () => {} });
  }

  /** Called by host-detail when the parent Management tab is opened. */
  activate(): void {
    this.select(this.selected());
    this.probeFirewall();
    this.ensureModules();
  }
}
