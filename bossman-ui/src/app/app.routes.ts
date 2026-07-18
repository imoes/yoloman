import { Routes } from '@angular/router';
import { authGuard } from './core/auth/auth.guard';
import { adminGuard } from './core/auth/admin.guard';

export const routes: Routes = [
  { path: '', redirectTo: 'fleet', pathMatch: 'full' },
  {
    path: 'login',
    loadComponent: () => import('./features/auth/login/login.component').then((m) => m.LoginComponent),
  },
  {
    path: 'fleet',
    canActivate: [authGuard],
    loadComponent: () =>
      import('./features/fleet-overview/fleet-overview.component').then((m) => m.FleetOverviewComponent),
  },
  {
    path: 'ai-dashboard',
    canActivate: [authGuard],
    loadComponent: () => import('./features/ai-dashboard/ai-dashboard.component').then((m) => m.AiDashboardComponent),
  },
  {
    path: 'hosts',
    canActivate: [authGuard],
    loadComponent: () => import('./features/hosts/hosts-list.component').then((m) => m.HostsListComponent),
  },
  {
    path: 'hosts/:id',
    canActivate: [authGuard],
    loadComponent: () => import('./features/hosts/host-detail.component').then((m) => m.HostDetailComponent),
  },
  {
    // Chrome-less pop-out console window (opened via the host's Open console button).
    path: 'console/:id',
    canActivate: [authGuard],
    loadComponent: () => import('./features/hosts/console-page.component').then((m) => m.ConsolePageComponent),
  },
  {
    path: 'problems',
    canActivate: [authGuard],
    loadComponent: () => import('./features/problems/problems-list.component').then((m) => m.ProblemsListComponent),
  },
  {
    path: 'modules',
    canActivate: [authGuard],
    loadComponent: () => import('./features/modules/modules-list.component').then((m) => m.ModulesListComponent),
  },
  {
    path: 'checks',
    canActivate: [authGuard],
    loadComponent: () => import('./features/checks/checks-catalog.component').then((m) => m.ChecksCatalogComponent),
  },
  {
    path: 'config-templates',
    canActivate: [authGuard],
    loadComponent: () => import('./features/config-templates/config-templates.component').then((m) => m.ConfigTemplatesComponent),
  },
  {
    path: 'config-codecs',
    canActivate: [authGuard],
    loadComponent: () => import('./features/config-codecs/config-codecs.component').then((m) => m.ConfigCodecsComponent),
  },
  {
    path: 'snmp-devices',
    canActivate: [authGuard],
    loadComponent: () => import('./features/snmp-devices/snmp-devices.component').then((m) => m.SnmpDevicesComponent),
  },
  {
    path: 'runbooks',
    canActivate: [authGuard],
    loadComponent: () => import('./features/runbooks/runbook-editor.component').then((m) => m.RunbookEditorComponent),
  },
  {
    path: 'scheduler',
    canActivate: [authGuard],
    loadComponent: () => import('./features/scheduler/scheduler.component').then((m) => m.SchedulerComponent),
  },
  {
    path: 'deploy',
    canActivate: [authGuard],
    loadComponent: () => import('./features/deploy/deploy.component').then((m) => m.DeployComponent),
  },
  {
    path: 'notifications',
    canActivate: [authGuard],
    loadComponent: () => import('./features/notifications/notifications.component').then((m) => m.NotificationsComponent),
  },
  {
    path: 'topology',
    canActivate: [authGuard],
    loadComponent: () => import('./features/topology/topology.component').then((m) => m.TopologyComponent),
  },
  {
    path: 'security',
    canActivate: [authGuard],
    loadComponent: () => import('./features/security/security.component').then((m) => m.SecurityComponent),
  },
  {
    path: 'plan-library',
    canActivate: [authGuard],
    loadComponent: () => import('./features/plans/plan-library.component').then((m) => m.PlanLibraryComponent),
  },
  {
    path: 'ou',
    canActivate: [authGuard],
    loadComponent: () => import('./features/ou-policy/ou-policy.component').then((m) => m.OuPolicyComponent),
  },
  {
    path: 'host-placement',
    canActivate: [authGuard],
    loadComponent: () => import('./features/host-placement/host-placement.component').then((m) => m.HostPlacementComponent),
  },
  {
    path: 'plans',
    canActivate: [authGuard],
    loadComponent: () => import('./features/plans/plans-list.component').then((m) => m.PlansListComponent),
  },
  {
    path: 'plans/:name',
    canActivate: [authGuard],
    loadComponent: () => import('./features/plans/plan-detail.component').then((m) => m.PlanDetailComponent),
  },
  {
    path: 'runs',
    canActivate: [authGuard],
    loadComponent: () => import('./features/runs/runs-list.component').then((m) => m.RunsListComponent),
  },
  {
    path: 'runs/:id',
    canActivate: [authGuard],
    loadComponent: () => import('./features/runs/run-detail.component').then((m) => m.RunDetailComponent),
  },
  {
    path: 'settings',
    canActivate: [authGuard],
    loadComponent: () => import('./features/settings/settings.component').then((m) => m.SettingsComponent),
  },
  {
    path: 'help',
    canActivate: [authGuard],
    loadComponent: () => import('./features/help/help.component').then((m) => m.HelpComponent),
  },
  {
    path: 'users',
    canActivate: [adminGuard],
    loadComponent: () => import('./features/admin/users-access.component').then((m) => m.UsersAccessComponent),
  },
  { path: '**', redirectTo: 'fleet' },
];
