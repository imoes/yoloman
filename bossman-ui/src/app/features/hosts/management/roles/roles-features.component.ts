import { Component, OnInit, computed, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatDialog } from '@angular/material/dialog';
import { forkJoin } from 'rxjs';
import { CatalogPackage, PackageCatalogService } from '../../../../core/services/package-catalog.service';
import { WizardContext, WizardService } from '../../../../core/services/wizard.service';
import { AddRolesWizardComponent, AddRolesWizardData } from './add-roles-wizard.component';

/** Roles & Features snap-in (MMC): lists the catalog's configurable server
 * packages with their install status; "Add roles and features" opens the
 * install wizard; an installed role's "Configure" reopens its config form. */
@Component({
  selector: 'app-roles-features',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-rf-head">
      <div>
        <h3>Roles &amp; Features</h3>
        <p class="bm-dim">Install and configure server roles on this host — like Windows Server Manager.</p>
      </div>
      <button mat-flat-button color="primary" (click)="openWizard()" [disabled]="!ready()">
        <mat-icon>add</mat-icon> Add roles and features
      </button>
    </div>

    @if (!ready()) {
      <p class="bm-dim">Loading catalog…</p>
    } @else if (!hasInstalled()) {
      <p class="bm-dim">No configurable roles are installed yet. Use <strong>Add roles and features</strong> to install one.</p>
    } @else {
      <input class="bm-rf-search" placeholder="Search installed roles…" [ngModel]="query()" (ngModelChange)="query.set($event)" />
      <table class="bm-rf-tbl">
        <thead><tr><th>Role</th><th>Category</th><th>Version</th><th></th></tr></thead>
        <tbody>
          @for (r of rows(); track r.name) {
            <tr>
              <td><mat-icon class="bm-rf-ic">{{ r.icon }}</mat-icon> {{ r.label }}</td>
              <td class="bm-dim">{{ r.category }}</td>
              <td class="bm-mono">{{ r.version || '—' }}</td>
              <td>
                @if (r.template) {
                  <button mat-stroked-button (click)="configure(r.name)"><mat-icon>tune</mat-icon> Configure</button>
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
    .bm-rf-on { background: color-mix(in srgb, var(--bm-green, #2e7d32) 20%, transparent); }
    .bm-mono { font-family: ui-monospace, monospace; font-size: 12px; }
  `],
})
export class RolesFeaturesComponent implements OnInit {
  private catalogSvc = inject(PackageCatalogService);
  private wizard = inject(WizardService);
  private dialog = inject(MatDialog);
  agentId = input.required<string>();

  private catalog = signal<Record<string, CatalogPackage>>({});
  private context = signal<WizardContext | null>(null);
  ready = computed(() => Object.keys(this.catalog()).length > 0 && this.context() !== null);
  hasInstalled = computed(() => {
    const inst = this.context()?.installed ?? {};
    return Object.entries(this.catalog()).some(([n, e]) => e.kind !== 'config' && n in inst);
  });
  query = signal('');

  // Only INSTALLED roles are listed — not-installed packages are discovered via
  // "Add roles and features", so showing all 80 here was just noise.
  rows = computed(() => {
    const ctx = this.context();
    const q = this.query().trim().toLowerCase();
    return Object.entries(this.catalog())
      .filter(([, e]) => e.kind !== 'config') // base-system config files live in the Configuration tab
      .map(([name, e]) => ({
        name, label: e.label, category: e.category, icon: e.icon, template: e.template,
        installed: !!ctx && name in ctx.installed,
        version: ctx?.installed[name] ?? '',
      }))
      .filter((r) => r.installed)
      .filter((r) => !q || r.name.toLowerCase().includes(q) || r.label.toLowerCase().includes(q) || r.category.toLowerCase().includes(q))
      .sort((a, b) => a.label.localeCompare(b.label));
  });

  ngOnInit(): void { this.reload(); }

  reload(refresh = false): void {
    forkJoin({ cat: this.catalogSvc.catalog(), ctx: this.wizard.context(this.agentId(), refresh) }).subscribe({
      next: ({ cat, ctx }) => { this.catalog.set(cat.packages); this.context.set(ctx); },
      error: () => {},
    });
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
}
