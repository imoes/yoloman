import { Component, computed, inject, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { AppsService, AppSummary } from '../../core/services/apps.service';
import { AppDeployComponent } from './app-deploy.component';

/**
 * App Store (app-system increment 1) — the unified catalog of deployable Apps,
 * a read-model over package-catalog + config templates (see docs/app-model.md).
 * Increment 1 is a scaffold: browse Apps grouped by category, each showing its
 * supported target tiers (native | docker | k8s) and whether it is configurable
 * by values. Deploy + the target picker + the values form arrive in later
 * increments; this establishes the surface and the /apps API seam.
 */
@Component({
  selector: 'app-app-store',
  standalone: true,
  imports: [MatIconModule, AppDeployComponent],
  template: `
    <div class="bm-page">
      <header class="bm-page-head">
        <h1>App Store</h1>
        <span class="bm-dim">{{ total() }} apps · one lifecycle across native · docker · k8s</span>
      </header>

      @if (loading()) { <p class="bm-dim">Loading apps…</p> }
      @else if (err()) { <p class="bm-err">{{ err() }}</p> }
      @else {
        <div class="bm-as-toolbar">
          <input class="bm-as-search" placeholder="Search apps…" [value]="query()"
                 (input)="query.set($any($event.target).value)" />
        </div>

        @if (selected(); as sel) {
          <div class="bm-as-deploy">
            <app-app-deploy [app]="sel" />
            <button class="bm-as-close" (click)="selected.set(null)" title="Close">
              <mat-icon>close</mat-icon>
            </button>
          </div>
        }
        @for (grp of groups(); track grp.category) {
          <section class="bm-as-group">
            <div class="bm-as-cat">{{ grp.category }} <span class="bm-dim">· {{ grp.apps.length }}</span></div>
            <div class="bm-as-grid">
              @for (a of grp.apps; track a.id) {
                <button class="bm-as-card" [class.sel]="selected()?.id === a.id" (click)="select(a)">
                  <mat-icon class="bm-as-ic">{{ material(a.icon) }}</mat-icon>
                  <div class="bm-as-body">
                    <div class="bm-as-label">{{ a.label }}</div>
                    <div class="bm-as-desc">{{ a.description || a.id }}</div>
                    <div class="bm-as-badges">
                      @for (t of targetsOf(a); track t) { <span class="bm-as-tier">{{ t }}</span> }
                      @if (a.configurable) { <span class="bm-as-cfg">configurable</span> }
                    </div>
                  </div>
                </button>
              }
            </div>
          </section>
        }
        @if (!groups().length) { <p class="bm-dim">No apps match “{{ query() }}”.</p> }
      }
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1100px; }
    .bm-page-head { display: flex; align-items: baseline; gap: 12px; margin-bottom: 16px; }
    .bm-page-head h1 { margin: 0; font-size: 22px; }
    .bm-dim { opacity: 0.6; font-size: 13px; }
    .bm-err { color: var(--mat-sys-error, #c62828); }
    .bm-as-toolbar { margin-bottom: 16px; }
    .bm-as-search { width: 320px; max-width: 100%; box-sizing: border-box; padding: 8px 12px; border-radius: 8px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-as-group { margin-bottom: 20px; }
    .bm-as-cat { font-weight: 600; text-transform: capitalize; margin-bottom: 8px; }
    .bm-as-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 12px; }
    .bm-as-card { display: flex; gap: 12px; text-align: left; padding: 12px 14px; border-radius: 12px; cursor: pointer;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; }
    .bm-as-card:hover { border-color: var(--mat-sys-primary); }
    .bm-as-card.sel { border-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 8%, transparent); }
    .bm-as-ic { font-size: 26px; width: 26px; height: 26px; opacity: 0.85; }
    .bm-as-body { min-width: 0; }
    .bm-as-label { font-weight: 600; font-size: 14px; }
    .bm-as-desc { font-size: 12px; opacity: 0.7; margin: 2px 0 6px; overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
    .bm-as-badges { display: flex; flex-wrap: wrap; gap: 4px; }
    .bm-as-tier { font-size: 10.5px; padding: 1px 7px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-as-cfg { font-size: 10.5px; padding: 1px 7px; border-radius: 999px; border: 1px solid var(--bm-green, #2e7d32); color: var(--bm-green, #2e7d32); }
    .bm-as-deploy { position: relative; margin-bottom: 20px; }
    .bm-as-close { position: absolute; top: 10px; right: 10px; background: none; border: none; color: inherit; cursor: pointer; opacity: 0.6; }
    .bm-as-close:hover { opacity: 1; }
  `],
})
export class AppStoreComponent {
  private apps = inject(AppsService);

  loading = signal(true);
  err = signal('');
  private all = signal<AppSummary[]>([]);
  query = signal('');
  selected = signal<AppSummary | null>(null);

  total = computed(() => this.all().length);

  groups = computed(() => {
    const q = this.query().trim().toLowerCase();
    const filtered = this.all().filter((a) =>
      !q || a.label.toLowerCase().includes(q) || a.id.toLowerCase().includes(q) || a.description.toLowerCase().includes(q));
    const by = new Map<string, AppSummary[]>();
    for (const a of filtered) (by.get(a.category) ?? by.set(a.category, []).get(a.category)!).push(a);
    return [...by.entries()].sort((x, y) => x[0].localeCompare(y[0]))
      .map(([category, apps]) => ({ category, apps: apps.sort((m, n) => m.label.localeCompare(n.label)) }));
  });

  constructor() {
    this.apps.list().subscribe({
      next: (r) => { this.all.set(r.apps); this.loading.set(false); },
      error: (e) => { this.err.set(e?.error?.detail || 'Failed to load apps.'); this.loading.set(false); },
    });
  }

  targetsOf(a: AppSummary): string[] {
    return Object.keys(a.targets || {}).filter((k) => (a.targets as Record<string, unknown>)[k]);
  }
  select(a: AppSummary): void { this.selected.set(a); }
  // The catalog icons are our IconComponent glyph names; map the common ones to
  // Material symbols for this scaffold (a fuller mapping can come later).
  material(icon: string): string {
    const m: Record<string, string> = { language: 'language', hub: 'hub', storage: 'storage', database: 'database',
      memory: 'memory', schedule: 'schedule', mail: 'mail', code: 'code', vpn_key: 'vpn_key', inventory_2: 'inventory_2' };
    return m[icon] || 'widgets';
  }
}
