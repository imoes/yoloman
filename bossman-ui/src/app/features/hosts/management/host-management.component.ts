import { Component, OnInit, computed, inject, input, signal, viewChild, viewChildren } from '@angular/core';
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
import { ServiceChecksComponent } from './service-checks/service-checks.component';
import { PackageConfigComponent, PackageConfigDef } from './packages/package-config.component';
import { BindZonesComponent } from './packages/bind-zones.component';
import { NfsExportsComponent } from './packages/nfs-exports.component';
import { DhcpdComponent } from './packages/dhcpd.component';
import { CronComponent } from './packages/cron.component';
import { AptReposComponent } from './packages/apt-repos.component';
import { SambaComponent } from './packages/samba.component';
import { PureFtpdComponent } from './packages/pure-ftpd.component';
import { ProftpdComponent } from './packages/proftpd.component';
import { CupsComponent } from './packages/cups.component';
import { NginxSitesComponent } from './packages/nginx-sites.component';
import { ApacheVhostsComponent } from './packages/apache-vhosts.component';
import { HaproxyConfigComponent } from './packages/haproxy-config.component';

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
    HostVirtComponent, RolesFeaturesComponent, ServiceChecksComponent, PackageConfigComponent, BindZonesComponent, NfsExportsComponent, DhcpdComponent,
    CronComponent, AptReposComponent, SambaComponent, PureFtpdComponent, ProftpdComponent, CupsComponent,
    NginxSitesComponent, ApacheVhostsComponent, HaproxyConfigComponent,
  ],
  template: `
    <div class="bm-mmc">
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
        <div class="bm-mmc-detailhead">
          <span class="bm-mmc-detailtitle">{{ selectedLabel() }}</span>
          <button type="button" class="bm-mmc-refresh" (click)="refreshSelected()" title="Refresh"><mat-icon>refresh</mat-icon> Refresh</button>
        </div>
        @if (visited().has('roles')) { <div [style.display]="show('roles')"><app-roles-features [agentId]="agentId()" /></div> }
        @if (visited().has('servicechecks')) { <div [style.display]="show('servicechecks')"><app-service-checks [agentId]="agentId()" /></div> }
        @if (visited().has('services')) { <div [style.display]="show('services')"><app-host-services [agentId]="agentId()" /></div> }
        @if (visited().has('updates')) { <div [style.display]="show('updates')"><app-host-updates [agentId]="agentId()" /></div> }
        @if (visited().has('logs')) { <div [style.display]="show('logs')"><app-host-logs [agentId]="agentId()" /></div> }
        @if (visited().has('accounts')) { <div [style.display]="show('accounts')"><app-host-accounts [agentId]="agentId()" /></div> }
        @if (visited().has('network')) { <div [style.display]="show('network')"><app-host-network [agentId]="agentId()" /></div> }
        @if (visited().has('firewall')) { <div [style.display]="show('firewall')"><app-host-firewall [agentId]="agentId()" /></div> }
        @if (visited().has('storage')) { <div [style.display]="show('storage')"><app-host-storage [agentId]="agentId()" /></div> }
        @if (visited().has('freeipa')) { <div [style.display]="show('freeipa')"><app-host-freeipa [agentId]="agentId()" /></div> }
        @if (visited().has('virt')) { <div [style.display]="show('virt')"><app-host-virt [agentId]="agentId()" /></div> }
        @if (visited().has('pkg-bind')) { <div [style.display]="show('pkg-bind')"><app-bind-zones [agentId]="agentId()" /></div> }
        @if (visited().has('pkg-nfs')) { <div [style.display]="show('pkg-nfs')"><app-nfs-exports [agentId]="agentId()" /></div> }
        @if (visited().has('pkg-dhcpd')) { <div [style.display]="show('pkg-dhcpd')"><app-dhcpd [agentId]="agentId()" /></div> }
        @if (visited().has('pkg-samba')) { <div [style.display]="show('pkg-samba')"><app-samba [agentId]="agentId()" /></div> }
        @if (visited().has('pkg-pureftpd')) { <div [style.display]="show('pkg-pureftpd')"><app-pure-ftpd [agentId]="agentId()" /></div> }
        @if (visited().has('pkg-proftpd')) { <div [style.display]="show('pkg-proftpd')"><app-proftpd [agentId]="agentId()" /></div> }
        @if (visited().has('pkg-cups')) { <div [style.display]="show('pkg-cups')"><app-cups [agentId]="agentId()" /></div> }
        @if (visited().has('pkg-nginx')) { <div [style.display]="show('pkg-nginx')"><app-nginx-sites [agentId]="agentId()" /></div> }
        @if (visited().has('pkg-apache')) { <div [style.display]="show('pkg-apache')"><app-apache-vhosts [agentId]="agentId()" /></div> }
        @if (visited().has('pkg-haproxy')) { <div [style.display]="show('pkg-haproxy')"><app-haproxy-config [agentId]="agentId()" /></div> }
        @if (visited().has('cron')) { <div [style.display]="show('cron')"><app-cron [agentId]="agentId()" /></div> }
        @if (visited().has('apt-repos')) { <div [style.display]="show('apt-repos')"><app-apt-repos [agentId]="agentId()" /></div> }
        @for (p of pkgConfigs; track p.id) {
          @if (visited().has(p.id)) { <div [style.display]="show(p.id)"><app-package-config [agentId]="agentId()" [def]="p" /></div> }
        }
      </section>
    </div>
  `,
  styles: [`
    .bm-mmc { display: grid; grid-template-columns: 280px 1fr; gap: 16px; align-items: start; }
    .bm-mmc-tree, .bm-mmc-detail {
      border: 1px solid var(--mat-sys-outline-variant); border-radius: 12px;
      background: var(--mat-sys-surface-container-low, rgba(127,127,127,0.04));
    }
    .bm-mmc-tree { padding: 8px 6px; min-height: 420px; }
    .bm-mmc-detail { padding: 14px 16px; min-width: 0; min-height: 420px; }
    .bm-mmc-detailhead { display: flex; align-items: center; justify-content: space-between; gap: 12px;
      padding-bottom: 10px; margin-bottom: 12px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-mmc-detailtitle { font-weight: 700; font-size: 15px; }
    .bm-mmc-refresh { display: inline-flex; align-items: center; gap: 4px; font: inherit; font-size: 12.5px; cursor: pointer;
      background: none; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; padding: 4px 11px; color: inherit; }
    .bm-mmc-refresh:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-mmc-refresh mat-icon { font-size: 16px; width: 16px; height: 16px; }
    .bm-mmc-cat { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; opacity: 0.55; padding: 10px 10px 4px; }
    .bm-mmc-node {
      display: flex; align-items: center; gap: 8px; width: 100%; text-align: left;
      background: none; border: none; border-left: 3px solid transparent; color: inherit;
      padding: 7px 10px; cursor: pointer; font-size: 13.5px; border-radius: 0 6px 6px 0;
    }
    .bm-mmc-node:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-mmc-node mat-icon { font-size: 18px; width: 18px; height: 18px; opacity: 0.8; }
    .bm-mmc-sel { border-left-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); font-weight: 600; }
    @media (max-width: 1280px) { .bm-mmc { grid-template-columns: 240px 1fr; } }
  `],
})
export class HostManagementComponent implements OnInit {
  private agentService = inject(AgentService);
  agentId = input.required<string>();
  /** Snap-in ids to hide (e.g. the standalone console hides monitoring
   * snap-ins like 'servicechecks' that are a Fleet-Commander concern). */
  hideSnapins = input<string[]>([]);

  /** Self-activate on init so a deep-link (?tab=management) loads the default
   * snap-in without waiting for a tab-change event. */
  ngOnInit(): void { this.activate(); this.loadInstalledPackages(); }

  selected = signal<string>('network');
  visited = signal<Set<string>>(new Set());

  /** Bespoke package snap-ins are surfaced only when their package is actually
   * installed, so the console tree matches Roles & Features (installed roles
   * only). Maps snap-in id → the package name(s) whose presence means the role
   * is installed. Non-listed snap-ins (network, logs, …) are always shown. */
  private readonly snapinPkgs: Record<string, string[]> = {
    'pkg-bind': ['bind9'],
    'pkg-nfs': ['nfs-kernel-server'],
    'pkg-dhcpd': ['isc-dhcp-server', 'kea-dhcp4-server'],
    'pkg-samba': ['samba'],
    'pkg-pureftpd': ['pure-ftpd'],
    'pkg-proftpd': ['proftpd-basic', 'proftpd'],
    'pkg-cups': ['cups', 'cups-daemon'],
    'pkg-nginx': ['nginx', 'nginx-core', 'nginx-full', 'nginx-light', 'nginx-extras'],
    'pkg-apache': ['apache2', 'httpd'],
    'pkg-haproxy': ['haproxy'],
  };
  private installedPkgs = signal<Set<string>>(new Set());

  private loadInstalledPackages(): void {
    this.agentService.callTool(this.agentId(), 'package_facts', {}).subscribe({
      next: (r) => {
        const data = (r as { result?: { data?: unknown } }).result?.data;
        const list = Array.isArray(data) ? data : [];
        const names = new Set<string>();
        for (const p of list) { const n = (p as { name?: string }).name; if (n) names.add(n); }
        this.installedPkgs.set(names);
      },
      error: () => {},
    });
  }

  private modulesSynced = false;

  private readonly snapins: SnapIn[] = [
    { id: 'roles', label: 'Roles & Features', icon: 'widgets', category: 'Server' },
    { id: 'servicechecks', label: 'Service checks', icon: 'network_check', category: 'Monitoring' },
    { id: 'services', label: 'Services', icon: 'settings_applications', category: 'Server' },
    { id: 'cron', label: 'Scheduled jobs', icon: 'schedule', category: 'Server' },
    { id: 'updates', label: 'Updates', icon: 'system_update_alt', category: 'Server' },
    { id: 'apt-repos', label: 'Software sources', icon: 'inventory_2', category: 'Server' },
    { id: 'logs', label: 'Logs', icon: 'article', category: 'Server' },
    { id: 'accounts', label: 'Accounts', icon: 'group', category: 'Server' },
    { id: 'network', label: 'Network', icon: 'lan', category: 'Network' },
    { id: 'firewall', label: 'Firewall', icon: 'security', category: 'Network' },
    { id: 'storage', label: 'Storage', icon: 'storage', category: 'Storage' },
    { id: 'freeipa', label: 'FreeIPA', icon: 'badge', category: 'Identity' },
    { id: 'virt', label: 'Virtualization', icon: 'dns', category: 'Virtualization' },
  ];

  /** Per-package config snapins (new "Package configuration" category). Each is
   * rendered by the generic PackageConfigComponent (codec round-trip) — it shows
   * "not installed" gracefully when the config file is absent. Codecs/templates
   * for these already ship; more are added as they're installed + verified. */
  /** Generic codec-editor snapins remain available for future packages; the
   * FTP/CUPS packages moved to bespoke snapins (user/printer management). */
  readonly pkgConfigs: PackageConfigDef[] = [];

  // bind gets a bespoke snapin (zone lifecycle + named.conf.local include), not
  // the generic codec editor.
  private readonly bindSnapin: SnapIn = { id: 'pkg-bind', label: 'BIND zones', icon: 'dns', category: 'Package configuration' };

  // NFS gets a bespoke list-table snapin (/etc/exports via the `exports` codec +
  // `exportfs -ra`), not the generic key/value editor.
  private readonly nfsSnapin: SnapIn = { id: 'pkg-nfs', label: 'NFS exports', icon: 'folder_shared', category: 'Package configuration' };

  // ISC DHCP server gets a bespoke snapin (scopes + reservations via the dhcpd
  // codec, plus lease list/delete), not the generic key/value editor.
  private readonly dhcpdSnapin: SnapIn = { id: 'pkg-dhcpd', label: 'DHCP server', icon: 'settings_ethernet', category: 'Package configuration' };

  // Samba gets a bespoke shares snapin (per-share cards + directory picker),
  // not the generic ini editor.
  private readonly sambaSnapin: SnapIn = { id: 'pkg-samba', label: 'Samba shares', icon: 'folder_shared', category: 'Package configuration' };

  // FTP + CUPS: bespoke snapins (virtual-user / printer management), not the
  // generic codec editor (which mangled their Apache-style block config).
  private readonly ftpCupsSnapins: SnapIn[] = [
    { id: 'pkg-pureftpd', label: 'Pure-FTPd', icon: 'drive_folder_upload', category: 'Package configuration' },
    { id: 'pkg-proftpd', label: 'ProFTPD', icon: 'drive_folder_upload', category: 'Package configuration' },
    { id: 'pkg-cups', label: 'CUPS printing', icon: 'print', category: 'Package configuration' },
  ];

  // nginx gets a bespoke site (server-block) snapin: site list + schema-driven
  // values form rendered through the nginx-vhost Class-B template (incl. TLS),
  // not the generic codec editor (nginx block syntax has no codec).
  private readonly nginxSnapin: SnapIn = { id: 'pkg-nginx', label: 'nginx sites', icon: 'public', category: 'Package configuration' };

  // Apache (apache2 on Debian, httpd on RedHat) gets a bespoke vhost snapin,
  // same pattern as nginx (per-file <VirtualHost> rendered from values via the
  // apache-vhost template incl. TLS), distro-aware enable (a2ensite vs conf.d).
  private readonly apacheSnapin: SnapIn = { id: 'pkg-apache', label: 'Apache vhosts', icon: 'public', category: 'Package configuration' };

  // HAProxy: single-file config (global/defaults/frontend/backend) rendered from
  // values via the haproxy template incl. TLS bind — a one-object editor, not a
  // per-file site list.
  private readonly haproxySnapin: SnapIn = { id: 'pkg-haproxy', label: 'HAProxy', icon: 'hub', category: 'Package configuration' };

  private allSnapins(): SnapIn[] {
    return [
      ...this.snapins,
      this.bindSnapin,
      this.nfsSnapin,
      this.dhcpdSnapin,
      this.sambaSnapin,
      ...this.ftpCupsSnapins,
      this.nginxSnapin,
      this.apacheSnapin,
      this.haproxySnapin,
      ...this.pkgConfigs.map((p) => ({ id: p.id, label: p.label, icon: p.icon, category: 'Package configuration' })),
    ];
  }

  tree = computed(() => {
    const groups = new Map<string, SnapIn[]>();
    const hidden = new Set(this.hideSnapins());
    const installed = this.installedPkgs();
    for (const s of this.allSnapins()) {
      if (hidden.has(s.id)) continue;
      // A bespoke package snap-in is shown only when its package is installed,
      // so the tree matches Roles & Features (installed only) — e.g. ProFTPD's
      // snap-in stays hidden until proftpd is installed.
      const pkgs = this.snapinPkgs[s.id];
      if (pkgs && !pkgs.some((p) => installed.has(p))) continue;
      // The firewall snapin now auto-detects its backend (firewalld/ufw/
      // iptables) and iptables is always present, so it is always shown —
      // no firewall-cmd gate anymore.
      (groups.get(s.category) ?? groups.set(s.category, []).get(s.category)!).push(s);
    }
    return [...groups.entries()].map(([category, items]) => ({ category, items }));
  });

  selectedLabel = computed(() => this.allSnapins().find((s) => s.id === this.selected())?.label ?? '');
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
  private pkgPanels = viewChildren(PackageConfigComponent);
  private bindZones = viewChild(BindZonesComponent);
  private nfsExports = viewChild(NfsExportsComponent);
  private dhcpd = viewChild(DhcpdComponent);
  private cron = viewChild(CronComponent);
  private aptRepos = viewChild(AptReposComponent);
  private samba = viewChild(SambaComponent);
  private pureftpd = viewChild(PureFtpdComponent);
  private proftpd = viewChild(ProftpdComponent);
  private cups = viewChild(CupsComponent);
  private nginxSites = viewChild(NginxSitesComponent);
  private apacheVhosts = viewChild(ApacheVhostsComponent);
  private haproxyConfig = viewChild(HaproxyConfigComponent);

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
        case 'pkg-bind': this.bindZones()?.loadOnce(); break;
        case 'pkg-nfs': this.nfsExports()?.loadOnce(); break;
        case 'pkg-dhcpd': this.dhcpd()?.loadOnce(); break;
        case 'pkg-samba': this.samba()?.loadOnce(); break;
        case 'pkg-pureftpd': this.pureftpd()?.loadOnce(); break;
        case 'pkg-proftpd': this.proftpd()?.loadOnce(); break;
        case 'pkg-cups': this.cups()?.loadOnce(); break;
        case 'pkg-nginx': this.nginxSites()?.loadOnce(); break;
        case 'pkg-apache': this.apacheVhosts()?.loadOnce(); break;
        case 'pkg-haproxy': this.haproxyConfig()?.loadOnce(); break;
        case 'cron': this.cron()?.loadOnce(); break;
        case 'apt-repos': this.aptRepos()?.loadOnce(); break;
        // 'roles' loads itself on init.
        default:
          // Package-config snapins (pkg-*): find the matching generic panel.
          this.pkgPanels().find((p) => p.def().id === id)?.loadOnce();
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
    this.ensureModules();
  }
}
