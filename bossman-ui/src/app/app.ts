import { Component, computed, inject } from '@angular/core';
import { RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AuthService } from './core/auth/auth.service';

interface NavItem {
  path: string;
  label: string;
  icon: string;
}

const NAV_ITEMS: NavItem[] = [
  { path: '/fleet', label: 'Fleet Overview', icon: 'dashboard' },
  { path: '/hosts', label: 'Hosts', icon: 'dns' },
  { path: '/topology', label: 'Topology', icon: 'account_tree' },
  { path: '/plans', label: 'Plans', icon: 'checklist' },
  { path: '/runs', label: 'Runs', icon: 'history' },
  { path: '/settings', label: 'Settings', icon: 'settings' },
];

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [RouterOutlet, RouterLink, RouterLinkActive, MatIconModule, MatButtonModule],
  templateUrl: './app.html',
  styleUrl: './app.scss',
})
export class App {
  auth = inject(AuthService);
  navItems = NAV_ITEMS;
  isLoggedIn = computed(() => this.auth.isLoggedIn());
}
