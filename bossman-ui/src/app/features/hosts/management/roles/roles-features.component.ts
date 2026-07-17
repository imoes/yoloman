import { Component, OnInit, computed, inject, input, signal } from '@angular/core';
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
  imports: [MatButtonModule, MatIconModule],
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
    } @else {
      <table class="bm-rf-tbl">
        <thead><tr><th>Role</th><th>Category</th><th>Status</th><th>Version</th><th></th></tr></thead>
        <tbody>
          @for (r of rows(); track r.name) {
            <tr>
              <td><mat-icon class="bm-rf-ic">{{ r.icon }}</mat-icon> {{ r.label }}</td>
              <td class="bm-dim">{{ r.category }}</td>
              <td>
                @if (r.installed) { <span class="bm-rf-badge bm-rf-on">Installed</span> }
                @else { <span class="bm-rf-badge">Not installed</span> }
              </td>
              <td class="bm-mono">{{ r.version || '—' }}</td>
              <td>
                @if (r.installed && r.template) {
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

  rows = computed(() => {
    const ctx = this.context();
    return Object.entries(this.catalog())
      .map(([name, e]) => ({
        name, label: e.label, category: e.category, icon: e.icon, template: e.template,
        installed: !!ctx && name in ctx.installed,
        version: ctx?.installed[name] ?? '',
      }))
      .sort((a, b) => Number(b.installed) - Number(a.installed) || a.label.localeCompare(b.label));
  });

  ngOnInit(): void { this.reload(); }

  reload(): void {
    forkJoin({ cat: this.catalogSvc.catalog(), ctx: this.wizard.context(this.agentId()) }).subscribe({
      next: ({ cat, ctx }) => { this.catalog.set(cat.packages); this.context.set(ctx); },
      error: () => {},
    });
  }

  private open(preselect?: string): void {
    const ctx = this.context();
    if (!ctx) return;
    const data: AddRolesWizardData = {
      agentId: this.agentId(), hostName: this.agentId(), catalog: this.catalog(), context: ctx, preselect,
    };
    this.dialog.open(AddRolesWizardComponent, { data, width: 'min(1080px, 94vw)', maxWidth: '94vw' })
      .afterClosed().subscribe((changed) => { if (changed) this.reload(); });
  }

  openWizard(): void { this.open(); }
  configure(name: string): void { this.open(name); }
}
