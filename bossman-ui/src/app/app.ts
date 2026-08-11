import { Component, HostListener, OnDestroy, computed, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { NavigationEnd, Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { filter } from 'rxjs/operators';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { environment } from '../environments/environment';
import { AuthService } from './core/auth/auth.service';
import { ChatDockComponent } from './features/chat/chat-dock.component';
import { IconComponent } from './shared/components/icon/icon.component';
import { FleetSearchComponent } from './features/fleet-overview/fleet-search.component';
import { EventBrowserComponent } from './features/events/event-browser.component';

// Route → bespoke icon name (icon.component's set). Keyed by path so the nav
// data stays declarative and the icon set can evolve independently.
const NAV_ICON: Record<string, string> = {
  '/fleet': 'fleet', '/problems': 'problems', '/topology': 'topology', '/security': 'security',
  '/host-placement': 'host-placement', '/plan-library': 'roles', '/runbooks': 'workflow', '/deploy': 'deploy',
  '/runs': 'runs', '/help': 'help',
  '/noc': 'noc', '/business-services': 'business-services', '/capacity': 'capacity',
  '/scheduler': 'scheduler', '/rollouts': 'rollouts',
  '/hosts': 'hosts', '/notifications': 'notifications', '/ou': 'ou-policy', '/modules': 'modules',
  '/checks': 'checks', '/config-templates': 'config-templates', '/config-codecs': 'config-templates',
  '/snmp-devices': 'hosts', '/users': 'users', '/settings': 'settings', '/vault': 'settings',
  '/apps': 'modules', '/systems': 'topology', '/disk-templates': 'deploy', '/docker-state': 'hosts',
  // Previously unmapped (they silently fell back to 'fleet'). Icon names repeat across workspaces where
  // the set has no closer match — harmless, since each appears in a different tree.
  '/blueprint': 'template', '/events': 'notifications', '/event-browser': 'runs', '/compliance': 'checks',
  '/config-sync': 'config-templates', '/audit': 'users', '/change-proposals': 'checks',
};

interface NavItem {
  path: string;
  label: string;
  icon: string;
  adminOnly?: boolean;
}

/**
 * A workspace groups the routes that belong to one job (docs/ui-workspaces.md). Picking a workspace
 * swaps the tree below the switcher, so related functions live together and the nav never outgrows the
 * viewport — the ConfigMgr idea in our macOS form (design-philosophy §4: source list → content →
 * inspector), not a Windows ribbon.
 */
interface Workspace {
  id: string;
  label: string;
  icon: string;
  hint: string;
  items: NavItem[];
}

// The five workspaces (docs/ui-workspaces.md). Every existing route keeps its URL — this is regrouping,
// not rewriting. The AI Dashboard stays reachable from Fleet Overview, and Help sits in the footer so it
// is one click from anywhere.
//
// Library is deliberately the single home for everything AUTHORABLE: per docs/resource-protocol.md a
// role, a sequence, a blueprint, a template, a module and a check are all Resource implementations
// answering the same verbs — so they are one list of types, not seven unrelated pages. Deploy then holds
// what binds Library to Fleet (a Deployment is the recorded apply() on a target).
const WORKSPACES: Workspace[] = [
  {
    id: 'monitor',
    label: 'Monitor',
    icon: 'fleet',
    hint: 'What is happening',
    items: [
      { path: '/fleet', label: 'Fleet Overview', icon: 'dashboard' },
      { path: '/noc', label: 'NOC view', icon: 'desktop_windows' },
      { path: '/problems', label: 'Problems', icon: 'report_problem' },
      { path: '/events', label: 'Event Console', icon: 'inbox' },
      { path: '/business-services', label: 'Business services', icon: 'hub' },
      { path: '/capacity', label: 'Capacity', icon: 'trending_up' },
      { path: '/topology', label: 'Topology', icon: 'account_tree' },
      { path: '/security', label: 'Security', icon: 'security' },
      { path: '/compliance', label: 'Compliance', icon: 'verified_user' },
      { path: '/runs', label: 'Runs', icon: 'history' },
      { path: '/audit', label: 'Audit log', icon: 'receipt_long', adminOnly: true },
    ],
  },
  {
    id: 'fleet',
    label: 'Fleet',
    icon: 'hosts',
    hint: 'The assets you manage',
    items: [
      { path: '/hosts', label: 'Hosts', icon: 'dns' },
      { path: '/fleet-search', label: 'Fleet search', icon: 'search' },
      { path: '/systems', label: 'Systems', icon: 'lan' },
      { path: '/docker-state', label: 'Docker state', icon: 'inventory_2' },
      { path: '/snmp-devices', label: 'Devices', icon: 'router' },
      { path: '/host-placement', label: 'Host placement', icon: 'lan' },
      { path: '/ou', label: 'OU / Policy', icon: 'domain' },
    ],
  },
  {
    id: 'library',
    label: 'Library',
    icon: 'roles',
    hint: 'Everything you can apply',
    items: [
      { path: '/plan-library', label: 'Roles', icon: 'folder_special' },
      { path: '/runbooks', label: 'Sequences', icon: 'account_tree' },
      { path: '/blueprint', label: 'Blueprints', icon: 'schema' },
      { path: '/blueprint-drafts', label: 'Blueprint drafts', icon: 'account_tree' },
      { path: '/apps', label: 'App Store', icon: 'apps' },
      { path: '/docker-apps', label: 'Docker apps', icon: 'inventory_2' },
      { path: '/modules', label: 'Modules', icon: 'extension' },
      { path: '/checks', label: 'Checks', icon: 'fact_check' },
      { path: '/config-templates', label: 'Config templates', icon: 'dataset' },
      { path: '/config-codecs', label: 'Config codecs', icon: 'data_object' },
      { path: '/disk-templates', label: 'Disk images', icon: 'install_desktop' },
    ],
  },
  {
    id: 'deploy',
    label: 'Deploy',
    icon: 'deploy',
    hint: 'Library applied to the fleet',
    items: [
      { path: '/deploy', label: 'Deploy', icon: 'rocket_launch' },
      { path: '/change-proposals', label: 'Change proposals', icon: 'rule' },
      { path: '/rollouts', label: 'Rollouts', icon: 'waves' },
      { path: '/scheduler', label: 'Scheduler', icon: 'schedule' },
      { path: '/config-sync', label: 'Config distribution', icon: 'sync' },
    ],
  },
  {
    id: 'admin',
    label: 'Admin',
    icon: 'settings',
    hint: 'Access and system settings',
    items: [
      { path: '/users', label: 'Users & Access', icon: 'admin_panel_settings', adminOnly: true },
      { path: '/notifications', label: 'Notifications', icon: 'notifications' },
      { path: '/vault', label: 'Vault', icon: 'key', adminOnly: true },
      { path: '/settings', label: 'Settings', icon: 'settings' },
    ],
  },
];

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [RouterOutlet, RouterLink, RouterLinkActive, MatIconModule, MatButtonModule, ChatDockComponent, IconComponent, FleetSearchComponent, EventBrowserComponent],
  templateUrl: './app.html',
  styleUrl: './app.scss',
})
export class App implements OnDestroy {
  auth = inject(AuthService);
  private router = inject(Router);
  private http = inject(HttpClient);
  navIcon(path: string): string { return NAV_ICON[path] ?? 'fleet'; }

  // Header Event-Console badge (top-right): number of jobs running RIGHT NOW
  // (plan runs / PXE restores / rollouts) from GET /activity/running, polled.
  // Clicking it opens the Event Browser.
  runningJobs = signal(0);
  // Event Browser opens as a popup overlay from the header badge (not a page).
  eventBrowserOpen = signal(false);
  private pollTimer: ReturnType<typeof setInterval> | null = null;
  private pollActivity(): void {
    if (!this.auth.isLoggedIn()) return;
    this.http.get<{ count: number }>(`${environment.apiUrl}/activity/running`).subscribe({
      next: (r) => this.runningJobs.set(r.count ?? 0),
      error: () => {},
    });
  }
  // Chromeless routes (e.g. the pop-out console) render bare — no nav/chat —
  // so a console window is just the terminal.
  private url = signal(this.router.url);
  chromeless = computed(() => this.url().startsWith('/console/') || this.url().startsWith('/vm-console/'));
  // P5: global Ctrl/Cmd+K fleet-search overlay (Checkmk quicksearch parity) —
  // reuses FleetSearchComponent; closes on Esc and on any navigation.
  searchOpen = signal(false);
  constructor() {
    this.router.events
      .pipe(filter((e): e is NavigationEnd => e instanceof NavigationEnd))
      .subscribe((e) => {
        this.url.set(e.urlAfterRedirects);
        this.searchOpen.set(false);
        this.eventBrowserOpen.set(false);
        // Navigating hands control back to the route: the page you are on decides which workspace tree is
        // open, so a deep link is never shown under the wrong workspace.
        this.picked.set(null);
      });
    // Poll the running-jobs badge (light: one small count query every 15s).
    this.pollActivity();
    this.pollTimer = setInterval(() => this.pollActivity(), 15000);
  }

  ngOnDestroy(): void {
    if (this.pollTimer) clearInterval(this.pollTimer);
  }

  @HostListener('document:keydown', ['$event'])
  onKeydown(e: KeyboardEvent): void {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
      e.preventDefault();
      if (this.auth.isLoggedIn()) this.searchOpen.update((v) => !v);
    } else if (e.key === 'Escape' && this.searchOpen()) {
      this.searchOpen.set(false);
    } else if (e.key === 'Escape' && this.eventBrowserOpen()) {
      this.eventBrowserOpen.set(false);
    }
  }
  // Block M: hide admin-only entries (Users & Access) for non-admins. The
  // route's adminGuard and the backend's require_admin are the real gates;
  // this just keeps the nav honest.
  private forRole = (items: NavItem[]) =>
    items.filter((item) => !item.adminOnly || this.auth.role() === 'admin');

  workspaces = WORKSPACES;
  helpItem: NavItem = { path: '/help', label: 'Help', icon: 'help_outline' };

  /** The workspace the operator picked, if any. Null means "follow the route" (see activeWorkspace). */
  private picked = signal<string | null>(null);
  selectWorkspace(id: string): void { this.picked.set(id); }

  /**
   * Which workspace is showing.
   *
   * An explicit PICK wins — clicking a workspace has to switch the tree even while the current page
   * belongs to another workspace (browsing Library from /fleet is the normal way in). Any navigation
   * clears the pick (see the NavigationEnd handler), so the ROUTE then decides again: deep-linking or the
   * omnibox jumping into /modules lands in Library with the right tree open.
   */
  activeWorkspace = computed(() => {
    const p = this.picked();
    if (p) {
      const byPick = WORKSPACES.find((w) => w.id === p);
      if (byPick) return byPick;
    }
    const url = this.url();
    return WORKSPACES.find((w) => w.items.some((i) => url.startsWith(i.path))) ?? WORKSPACES[0];
  });

  /** The active workspace's entries, role-filtered. */
  workspaceItems = computed(() => this.forRole(this.activeWorkspace().items));

  isLoggedIn = computed(() => this.auth.isLoggedIn());
}
