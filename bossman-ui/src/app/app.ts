import { Component, computed, inject } from '@angular/core';
import { RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
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
  { path: '/ou', label: 'OU / Policy', icon: 'domain' },
  { path: '/host-placement', label: 'Host placement', icon: 'lan' },
  { path: '/modules', label: 'Modules', icon: 'extension' },
  { path: '/plans', label: 'Plans', icon: 'checklist' },
  { path: '/runs', label: 'Runs', icon: 'history' },
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
  // Block M: hide admin-only entries (Users & Access) for non-admins. The
  // route's adminGuard and the backend's require_admin are the real gates;
  // this just keeps the nav honest.
  navItems = computed(() =>
    NAV_ITEMS.filter((item) => !item.adminOnly || this.auth.role() === 'admin'),
  );
  isLoggedIn = computed(() => this.auth.isLoggedIn());
}
