import { Component, computed, inject, signal } from '@angular/core';
import { NavigationEnd, Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { filter } from 'rxjs/operators';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AuthService } from './core/auth/auth.service';
import { ChatDockComponent } from './features/chat/chat-dock.component';
import { IconComponent } from './shared/components/icon/icon.component';

// Route → bespoke icon name (icon.component's set). Keyed by path so the nav
// data stays declarative and the icon set can evolve independently.
const NAV_ICON: Record<string, string> = {
  '/fleet': 'fleet', '/problems': 'problems', '/topology': 'topology', '/security': 'security',
  '/host-placement': 'host-placement', '/plan-library': 'roles', '/runbooks': 'workflow', '/deploy': 'deploy',
  '/runs': 'runs', '/help': 'help',
  '/hosts': 'hosts', '/notifications': 'notifications', '/ou': 'ou-policy', '/modules': 'modules',
  '/checks': 'checks', '/config-templates': 'config-templates', '/config-codecs': 'config-templates',
  '/snmp-devices': 'hosts', '/users': 'users', '/settings': 'settings',
};

interface NavItem {
  path: string;
  label: string;
  icon: string;
  adminOnly?: boolean;
}

// Day-to-day operational views stay at the top level; configuration/admin
// surfaces are grouped under a collapsible "Setup" section (below). The AI
// Dashboard is reached from within Fleet Overview, not as its own nav entry.
//
// Automation is roles-centric (we dropped playbooks/tasks): one Roles library
// to author in, Deploy to run roles across hosts/groups, Runs for history —
// so the old Runbooks + Plans + Plan library trio collapses to just "Roles".
const MAIN_NAV: NavItem[] = [
  { path: '/fleet', label: 'Fleet Overview', icon: 'dashboard' },
  { path: '/hosts', label: 'Hosts', icon: 'dns' },
  { path: '/problems', label: 'Problems', icon: 'report_problem' },
  { path: '/topology', label: 'Topology', icon: 'account_tree' },
  { path: '/security', label: 'Security', icon: 'security' },
  { path: '/host-placement', label: 'Host placement', icon: 'lan' },
  { path: '/plan-library', label: 'Roles', icon: 'folder_special' },
  { path: '/runbooks', label: 'Workflow designer', icon: 'account_tree' },
  { path: '/scheduler', label: 'Scheduler', icon: 'schedule' },
  { path: '/deploy', label: 'Deploy', icon: 'rocket_launch' },
  { path: '/runs', label: 'Runs', icon: 'history' },
  { path: '/help', label: 'Help', icon: 'help_outline' },
];

const SETUP_NAV: NavItem[] = [
  { path: '/notifications', label: 'Notifications', icon: 'notifications' },
  { path: '/ou', label: 'OU / Policy', icon: 'domain' },
  { path: '/modules', label: 'Modules', icon: 'extension' },
  { path: '/checks', label: 'Checks', icon: 'fact_check' },
  { path: '/snmp-devices', label: 'Devices', icon: 'router' },
  { path: '/config-templates', label: 'Config templates', icon: 'dataset' },
  { path: '/config-codecs', label: 'Config codecs', icon: 'data_object' },
  { path: '/users', label: 'Users & Access', icon: 'admin_panel_settings', adminOnly: true },
  { path: '/settings', label: 'Settings', icon: 'settings' },
];

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [RouterOutlet, RouterLink, RouterLinkActive, MatIconModule, MatButtonModule, ChatDockComponent, IconComponent],
  templateUrl: './app.html',
  styleUrl: './app.scss',
})
export class App {
  auth = inject(AuthService);
  private router = inject(Router);
  navIcon(path: string): string { return NAV_ICON[path] ?? 'fleet'; }
  // Chromeless routes (e.g. the pop-out console) render bare — no nav/chat —
  // so a console window is just the terminal.
  private url = signal(this.router.url);
  chromeless = computed(() => this.url().startsWith('/console/'));
  constructor() {
    this.router.events
      .pipe(filter((e): e is NavigationEnd => e instanceof NavigationEnd))
      .subscribe((e) => this.url.set(e.urlAfterRedirects));
  }
  // Block M: hide admin-only entries (Users & Access) for non-admins. The
  // route's adminGuard and the backend's require_admin are the real gates;
  // this just keeps the nav honest.
  private forRole = (items: NavItem[]) =>
    items.filter((item) => !item.adminOnly || this.auth.role() === 'admin');
  mainItems = computed(() => this.forRole(MAIN_NAV));
  setupItems = computed(() => this.forRole(SETUP_NAV));
  // Setup section auto-opens when the current route is one of its entries, so
  // deep-linking into a config page doesn't leave it looking hidden.
  setupOpen = signal(false);
  setupActive = computed(() => this.setupItems().some((i) => this.url().startsWith(i.path)));
  toggleSetup(): void { this.setupOpen.update((v) => !v); }
  isLoggedIn = computed(() => this.auth.isLoggedIn());
}
