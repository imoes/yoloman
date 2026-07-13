import { Component, computed, inject, signal } from '@angular/core';
import { NavigationEnd, Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { filter } from 'rxjs/operators';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AuthService } from './core/auth/auth.service';
import { ChatDockComponent } from './features/chat/chat-dock.component';

interface NavItem {
  path: string;
  label: string;
  icon: string;
  adminOnly?: boolean;
}

// Day-to-day operational views stay at the top level; configuration/admin
// surfaces are grouped under a collapsible "Setup" section (below). The AI
// Dashboard is reached from within Fleet Overview, not as its own nav entry.
const MAIN_NAV: NavItem[] = [
  { path: '/fleet', label: 'Fleet Overview', icon: 'dashboard' },
  { path: '/problems', label: 'Problems', icon: 'report_problem' },
  { path: '/topology', label: 'Topology', icon: 'account_tree' },
  { path: '/security', label: 'Security', icon: 'security' },
  { path: '/host-placement', label: 'Host placement', icon: 'lan' },
  { path: '/runbooks', label: 'Runbooks', icon: 'terminal' },
  { path: '/plans', label: 'Plans', icon: 'checklist' },
  { path: '/plan-library', label: 'Plan library', icon: 'folder_special' },
  { path: '/deploy', label: 'Deploy', icon: 'rocket_launch' },
  { path: '/runs', label: 'Runs', icon: 'history' },
  { path: '/help', label: 'Help', icon: 'help_outline' },
];

const SETUP_NAV: NavItem[] = [
  { path: '/hosts', label: 'Hosts', icon: 'dns' },
  { path: '/notifications', label: 'Notifications', icon: 'notifications' },
  { path: '/ou', label: 'OU / Policy', icon: 'domain' },
  { path: '/modules', label: 'Modules', icon: 'extension' },
  { path: '/checks', label: 'Checks', icon: 'fact_check' },
  { path: '/users', label: 'Users & Access', icon: 'admin_panel_settings', adminOnly: true },
  { path: '/settings', label: 'Settings', icon: 'settings' },
];

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [RouterOutlet, RouterLink, RouterLinkActive, MatIconModule, MatButtonModule, ChatDockComponent],
  templateUrl: './app.html',
  styleUrl: './app.scss',
})
export class App {
  auth = inject(AuthService);
  private router = inject(Router);
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
