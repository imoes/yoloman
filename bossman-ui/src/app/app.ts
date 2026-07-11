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

const NAV_ITEMS: NavItem[] = [
  { path: '/fleet', label: 'Fleet Overview', icon: 'dashboard' },
  { path: '/ai-dashboard', label: 'AI Dashboard', icon: 'auto_awesome' },
  { path: '/problems', label: 'Problems', icon: 'report_problem' },
  { path: '/notifications', label: 'Notifications', icon: 'notifications' },
  { path: '/hosts', label: 'Hosts', icon: 'dns' },
  { path: '/topology', label: 'Topology', icon: 'account_tree' },
  { path: '/security', label: 'Security', icon: 'security' },
  { path: '/ou', label: 'OU / Policy', icon: 'domain' },
  { path: '/host-placement', label: 'Host placement', icon: 'lan' },
  { path: '/modules', label: 'Modules', icon: 'extension' },
  { path: '/checks', label: 'Checks', icon: 'fact_check' },
  { path: '/runbooks', label: 'Runbooks', icon: 'terminal' },
  { path: '/plans', label: 'Plans', icon: 'checklist' },
  { path: '/runs', label: 'Runs', icon: 'history' },
  { path: '/users', label: 'Users & Access', icon: 'admin_panel_settings', adminOnly: true },
  { path: '/settings', label: 'Settings', icon: 'settings' },
  { path: '/help', label: 'Help', icon: 'help_outline' },
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
  navItems = computed(() =>
    NAV_ITEMS.filter((item) => !item.adminOnly || this.auth.role() === 'admin'),
  );
  isLoggedIn = computed(() => this.auth.isLoggedIn());
}
