import { Component, OnInit, computed, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatDialog } from '@angular/material/dialog';
import { forkJoin, Observable, switchMap } from 'rxjs';
import { catalogCategory, CatalogPackage, PackageCatalogService } from '../../../../core/services/package-catalog.service';
import { RoleDeploymentDetail, WizardContext, WizardService } from '../../../../core/services/wizard.service';
import { AgentService } from '../../../../core/services/agent.service';
import { AddRolesWizardComponent, AddRolesWizardData } from './add-roles-wizard.component';
import { BlockedReasonDirective } from '../../../../shared/blocked-reason/blocked-reason.directive';

/** Roles & Features snap-in (MMC): lists the catalog's configurable server
 * packages with their install status; "Add roles and features" opens the
 * install wizard; an installed role's "Configure" reopens its config form. */
@Component({
  selector: 'app-roles-features',
  standalone: true,
  imports: [BlockedReasonDirective, FormsModule, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-rf-head">
      <div>
        <h3>Roles &amp; Features</h3>
        <p class="bm-dim">Install and configure server roles on this host.</p>
      </div>
      <span class="bm-why"><button mat-flat-button color="primary" (click)="openWizard()" [bmBlocked]="ready() ? '' : (loadError() ? 'The catalog could not be read — see the message below' : 'Loading the catalog and the OS family of this host…')">
        <mat-icon>add</mat-icon> Add roles and features
      </button></span>
    </div>

    @if (msg()) { <div class="bm-rf-msg" [class.err]="msgErr()">{{ msg() }}</div> }

    @if (loadError(); as err) {
      <!-- NOT "Loading…" forever: a failed read is a named state, with its reason and a way to try again. -->
      <div class="bm-rf-msg err">The catalog or this host's inventory could not be read: {{ err }}
        <button mat-button (click)="reload(true)"><mat-icon>refresh</mat-icon> Try again</button></div>
    } @else if (!ready()) {
      <p class="bm-dim">Loading catalog…</p>
    } @else if (!hasInstalled()) {
      <p class="bm-dim">No configurable roles are installed yet. Use <strong>Add roles and features</strong> to install one.</p>
    } @else {
      <input class="bm-rf-search" placeholder="Search installed roles…" [ngModel]="query()" (ngModelChange)="query.set($event)" />
      <table class="bm-rf-tbl">
        <thead><tr><th>Name</th><th>Type</th><th>Category</th><th>Version</th><th>Compliance</th><th></th></tr></thead>
        <tbody>
          @for (r of rows(); track r.name) {
            <tr>
              <td><mat-icon class="bm-rf-ic">{{ r.icon }}</mat-icon> {{ r.label }}</td>
              <td><span class="bm-rf-kind" [class.role]="r.kind === 'role'">{{ r.kind === 'role' ? 'Role' : 'Feature' }}</span></td>
              <td class="bm-dim">{{ r.category }}</td>
              <td class="bm-mono">{{ r.version || '—' }}</td>
              <td><span class="bm-rf-kind" [class.bm-rf-on]="r.compliance === 'compliant'">
                {{ complianceLabel(r.compliance) }}
              </span></td>
              <td class="bm-rf-actions">
                @if (confirming() === r.name) {
                  <span class="bm-rf-confirm">Remove {{ r.label }}:</span>
                  @if (r.compliance !== 'unmanaged') {
                    <button mat-stroked-button (click)="doRemove(r.name, false)" [disabled]="removing() === r.name">
                      Stop managing
                    </button>
                  }
                  <button mat-flat-button color="warn" (click)="doRemove(r.name, true)" [disabled]="removing() === r.name">
                    @if (removing() === r.name) { Removing… } @else { Uninstall }
                  </button>
                  <button mat-stroked-button (click)="confirming.set(null)" [disabled]="removing() === r.name">Cancel</button>
                } @else {
                  @if (r.compliance === 'noncompliant' || r.compliance === 'error' || r.compliance === 'blocked') {
                    <button mat-flat-button color="primary" (click)="correct(r.name)" [disabled]="correcting() === r.name">
                      <mat-icon>build</mat-icon> {{ correcting() === r.name ? 'Correcting…' : 'Correct drift' }}
                    </button>
                  }
                  @if (r.template) {
                    <button mat-stroked-button (click)="configure(r.name)"><mat-icon>tune</mat-icon> Configure</button>
                  }
                  <button mat-stroked-button class="bm-rf-remove" (click)="confirming.set(r.name)"><mat-icon>delete_outline</mat-icon> Remove</button>
                }
              </td>
            </tr>
          }
        </tbody>
      </table>
    }
  `,
  styles: [`
    .bm-rf-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; margin-bottom: 12px; }
    .bm-rf-head h3 { margin: 0; }
    .bm-dim { opacity: 0.62; margin: 2px 0 0; font-size: 13px; }
    .bm-rf-search { display: block; width: 100%; max-width: 380px; margin: 0 0 10px; padding: 7px 11px; border-radius: 6px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 13px; box-sizing: border-box; }
    .bm-rf-tbl { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-rf-tbl th { text-align: left; font-size: 12px; opacity: 0.6; padding: 6px 10px; }
    .bm-rf-tbl td { padding: 8px 10px; border-top: 1px solid var(--mat-sys-outline-variant); vertical-align: middle; }
    .bm-rf-ic { font-size: 18px; width: 18px; height: 18px; vertical-align: middle; opacity: 0.8; margin-right: 4px; }
    .bm-rf-badge { font-size: 11px; padding: 1px 9px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-rf-kind { font-size: 11px; padding: 1px 8px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-rf-kind.role { background: color-mix(in srgb, var(--mat-sys-primary) 22%, transparent); }
    .bm-rf-on { background: color-mix(in srgb, var(--bm-green, #2e7d32) 20%, transparent); }
    .bm-mono { font-family: ui-monospace, monospace; font-size: 12px; }
    .bm-rf-actions { white-space: nowrap; text-align: right; }
    .bm-rf-actions button { margin-left: 6px; }
    .bm-rf-remove { color: var(--bm-red, #d0021b); }
    .bm-rf-confirm { font-size: 13px; margin-right: 4px; }
    .bm-rf-msg { padding: 9px 12px; border-radius: 8px; font-size: 13px; margin-bottom: 12px;
      background: color-mix(in srgb, var(--bm-green, #1e9600) 16%, transparent); border: 1px solid color-mix(in srgb, var(--bm-green, #1e9600) 40%, transparent); }
    .bm-rf-msg.err { background: color-mix(in srgb, var(--bm-red, #d0021b) 16%, transparent); border-color: color-mix(in srgb, var(--bm-red, #d0021b) 45%, transparent); }
  `],
})
export class RolesFeaturesComponent implements OnInit {
  private catalogSvc = inject(PackageCatalogService);
  private wizard = inject(WizardService);
  private agents = inject(AgentService);
  private dialog = inject(MatDialog);
  agentId = input.required<string>();

  private catalog = signal<Record<string, CatalogPackage>>({});
  private context = signal<WizardContext | null>(null);
  private deployments = signal<RoleDeploymentDetail[]>([]);
  ready = computed(() => Object.keys(this.catalog()).length > 0 && this.context() !== null);
  hasInstalled = computed(() => {
    const inst = this.context()?.installed ?? {};
    return Object.entries(this.catalog()).some(([n, e]) => e.kind !== 'config' && n in inst);
  });
  query = signal('');
  // Uninstall: remove the role's packages via the `package` tool (state:absent).
  // Works in both shells — Bossman proxies /agents/{id}/tools/package to the
  // host, and the standalone interceptor rewrites it to the agent's own tool.
  confirming = signal<string | null>(null);
  removing = signal<string | null>(null);
  correcting = signal<string | null>(null);
  msg = signal('');
  msgErr = signal(false);

  // Only INSTALLED roles are listed — not-installed packages are discovered via
  // "Add roles and features", so showing all 80 here was just noise.
  rows = computed(() => {
    const ctx = this.context();
    const q = this.query().trim().toLowerCase();
    return Object.entries(this.catalog())
      .filter(([, e]) => e.kind !== 'config') // base-system config files live in the Configuration tab
      .map(([name, e]) => ({
        name, label: e.label, category: catalogCategory(e), icon: e.icon, template: e.template,
        kind: e.kind === 'role' ? 'role' : 'feature',   // installed catalog entries are role or feature; config lives elsewhere
        installed: !!ctx && name in ctx.installed,
        version: ctx?.installed[name] ?? '',
        compliance: this.complianceFor(name),
      }))
      .filter((r) => r.installed)
      .filter((r) => !q || r.name.toLowerCase().includes(q) || r.label.toLowerCase().includes(q) || r.category.toLowerCase().includes(q))
      .sort((a, b) => a.label.localeCompare(b.label));
  });

  ngOnInit(): void { this.reload(); }

  /** Why the last load failed, or null. Cleared when a load starts. */
  loadError = signal<string | null>(null);

  reload(refresh = false): void {
    this.loadError.set(null);
    forkJoin({
      cat: this.catalogSvc.catalog(),
      ctx: this.wizard.context(this.agentId(), refresh),
      deployments: this.wizard.listRoleDeployments(),
    }).subscribe({
      next: ({ cat, ctx, deployments }) => {
        this.catalog.set(cat.packages);
        this.context.set(ctx);
        this.deployments.set(deployments.deployments || []);
      },
      error: (e: { error?: { error?: string; detail?: string }; message?: string; status?: number }) => {
        const detail = e?.error?.detail || e?.error?.error || e?.message || 'request failed';
        this.loadError.set(e?.status ? `HTTP ${e.status}: ${detail}` : String(detail));
      },
    });
  }

  private complianceFor(name: string): string {
    const technical = `catalog__${name}`;
    for (const deployment of this.deployments()) {
      const item = deployment.items.find((x) => x.name === technical);
      if (!item) continue;
      const target = deployment.targets.find((x) => x.item_id === item.id && x.agent_id === this.agentId());
      if (target && target.state !== 'unmanaged') return target.state;
    }
    return 'unmanaged';
  }

  complianceLabel(state: string): string {
    return ({ compliant: 'Compliant', noncompliant: 'Drift', pending: 'Pending', installing: 'Installing',
      blocked: 'Blocked', error: 'Error', not_applicable: 'Not applicable', unknown: 'Unknown',
      unmanaged: 'Installed, unmanaged' } as Record<string, string>)[state] || state;
  }

  private open(preselect?: string): void {
    const ctx = this.context();
    if (!ctx) return;
    const data: AddRolesWizardData = {
      agentId: this.agentId(), hostName: ctx.host || this.agentId(), catalog: this.catalog(), context: ctx, preselect,
    };
    this.dialog.open(AddRolesWizardComponent, { data, width: 'min(1080px, 94vw)', maxWidth: '94vw' })
      .afterClosed().subscribe((changed) => { if (changed) this.reload(true); });
  }

  openWizard(): void { this.open(); }
  configure(name: string): void { this.open(name); }

  /** Uninstall an installed role: resolve its family-specific packages from the
   * wizard context and call the `package` tool with state:absent. apt/dnf's own
   * maintainer scripts stop+disable the service on removal. */
  doRemove(name: string, uninstall: boolean): void {
    const ctx = this.context();
    const resolved = ctx?.catalog_resolved?.[name];
    const pkgs = resolved?.packages ?? [];
    const label = this.catalog()[name]?.label || name;
    if (uninstall && !pkgs.length) {
      this.msg.set(`No packages are resolved for "${label}" on this host — nothing to remove.`);
      this.msgErr.set(true);
      this.confirming.set(null);
      return;
    }
    this.removing.set(name);
    this.msg.set('');
    const managed = this.managedTargetFor(name);
    const action: Observable<unknown> = managed
      ? this.wizard.removeRoleTarget(managed.deploymentId, managed.targetId, uninstall ? 'uninstall' : 'unmanage')
      : this.agents.callTool(this.agentId(), 'package', { name: pkgs, state: 'absent' });
    action.subscribe({
      next: () => {
        this.removing.set(null);
        this.confirming.set(null);
        this.msgErr.set(false);
        this.msg.set(uninstall
          ? `${label} uninstalled${pkgs.length ? ` (${pkgs.join(', ')})` : ''}.`
          : `${label} is no longer managed; the installed software was left unchanged.`);
        this.reload(true);
      },
      error: (e: { error?: { error?: string; detail?: string }; message?: string }) => {
        this.removing.set(null);
        this.msgErr.set(true);
        this.msg.set(`Removing ${label} failed: ${e?.error?.error || e?.error?.detail || e?.message || 'request error'}`);
      },
    });
  }

  correct(name: string): void {
    const managed = this.managedTargetFor(name);
    if (!managed || !window.confirm('Apply the desired role configuration again to correct this host?')) return;
    const label = this.catalog()[name]?.label || name;
    this.correcting.set(name);
    this.msg.set('');
    this.wizard.remediateRoleTargets(managed.deploymentId, [managed.targetId]).pipe(
      switchMap(() => this.wizard.reconcileRoleDeployment(managed.deploymentId)),
    ).subscribe({
      next: () => {
        this.correcting.set(null);
        this.msgErr.set(false);
        this.msg.set(`${label} was reconciled with its desired state.`);
        this.reload(true);
      },
      error: (e: { error?: { error?: string; detail?: string }; message?: string }) => {
        this.correcting.set(null);
        this.msgErr.set(true);
        this.msg.set(`Correcting ${label} failed: ${e?.error?.error || e?.error?.detail || e?.message || 'request error'}`);
      },
    });
  }

  private managedTargetFor(name: string): { deploymentId: string; targetId: string } | null {
    const technical = `catalog__${name}`;
    for (const deployment of this.deployments()) {
      const item = deployment.items.find((x) => x.name === technical);
      if (!item) continue;
      const target = deployment.targets.find((x) => x.item_id === item.id && x.agent_id === this.agentId() && x.state !== 'unmanaged');
      if (target) return { deploymentId: deployment.id, targetId: target.id };
    }
    return null;
  }
}
