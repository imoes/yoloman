import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { marked } from 'marked';
import { CheckCatalogEntry, CheckOption } from '../../core/models/check.model';
import { CheckService } from '../../core/services/check.service';

interface CheckDetail {
  name: string;
  metadata: Record<string, unknown>;
  star_code: string;
}
interface CategoryGroup {
  name: string;
  checks: CheckCatalogEntry[];
}

/** The check library browser (Block G9): every check in checks.d — Checkmk
 * checks translated to read-only Starlark, plus custom checks. 1444 checks is
 * a lot, so they're grouped into collapsible CATEGORIES; each check row expands
 * like a module to show its detailed description (for human + AI), parameters,
 * and Starlark source. Assigning a check to a host/group/OU happens on the host
 * Checks tab and in OU / Policy; this page is the catalog + progress view. */
@Component({
  selector: 'app-checks-catalog',
  standalone: true,
  imports: [FormsModule, MatCardModule, MatFormFieldModule, MatInputModule, MatIconModule, MatButtonModule],
  template: `
    <div class="bm-page">
      <div class="bm-header-row">
        <h1>Checks</h1>
        <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Refresh</button>
      </div>
      <p class="bm-subtitle">
        The monitoring check library (<code>checks.d</code>) — Checkmk checks translated to read-only
        Starlark, plus custom checks. Grouped by category; expand a check for its full description.
      </p>

      <mat-card class="bm-panel">
        <mat-card-content>
          <div class="bm-count">
            <span class="bm-big">{{ checks().length }}</span> checks in
            <span class="bm-big2">{{ groups().length }}</span> categories
            @if (loading()) { <span class="bm-dim">— loading…</span> }
          </div>
          <mat-form-field appearance="outline" class="bm-search">
            <mat-icon matPrefix>search</mat-icon>
            <mat-label>Filter checks</mat-label>
            <input matInput [ngModel]="query()" (ngModelChange)="query.set($event)" placeholder="name or description" />
          </mat-form-field>

          @for (g of groups(); track g.name) {
            <div class="bm-cat">
              <div class="bm-cat-head" (click)="toggleCat(g.name)">
                <mat-icon>{{ isCatOpen(g.name) ? 'expand_more' : 'chevron_right' }}</mat-icon>
                <span class="bm-cat-name">{{ g.name }}</span>
                <span class="bm-cat-count">{{ g.checks.length }}</span>
              </div>
              @if (isCatOpen(g.name)) {
                <table class="bm-table">
                  <tbody>
                    @for (c of g.checks; track c.name) {
                      <tr class="bm-row-link" [class.bm-row-selected]="expanded() === c.name" (click)="toggle(c)">
                        <td class="bm-mono">{{ c.name }}</td>
                        <td class="bm-dim">{{ c.short_description }}</td>
                        <td class="bm-num">{{ optionCount(c) }} param(s)</td>
                        <td><span class="bm-src">{{ c.source }}</span></td>
                      </tr>
                      @if (expanded() === c.name) {
                        <tr class="bm-expand-row">
                          <td colspan="4">
                            @if (detail(); as d) {
                              <div class="bm-detail">
                                <article class="bm-md" [innerHTML]="descriptionHtml()"></article>
                                @if (optionRows(d).length) {
                                  <h4>Parameters</h4>
                                  <table class="bm-opts">
                                    <thead><tr><th>Name</th><th>Type</th><th>Default</th><th>Description</th></tr></thead>
                                    <tbody>
                                      @for (o of optionRows(d); track o.key) {
                                        <tr>
                                          <td class="bm-mono">{{ o.key }}{{ o.spec.required ? ' *' : '' }}</td>
                                          <td>{{ o.spec.type }}</td>
                                          <td class="bm-mono">{{ o.spec.default ?? '' }}</td>
                                          <td class="bm-dim">{{ o.spec.description || '' }}</td>
                                        </tr>
                                      }
                                    </tbody>
                                  </table>
                                }
                                <h4>Starlark source</h4>
                                <pre class="bm-code">{{ d.star_code }}</pre>
                              </div>
                            } @else {
                              <div class="bm-detail bm-dim">Loading…</div>
                            }
                          </td>
                        </tr>
                      }
                    }
                  </tbody>
                </table>
              }
            </div>
          } @empty {
            @if (!loading()) {
              <p class="bm-dim">
                @if (checks().length) { No checks match “{{ query() }}”. }
                @else { No checks yet — the translation batch fills checks.d as it runs. }
              </p>
            }
          }
        </mat-card-content>
      </mat-card>
    </div>
  `,
  styles: [
    `
      .bm-page { padding: 24px; }
      .bm-header-row { display: flex; align-items: center; justify-content: space-between; }
      .bm-subtitle { opacity: 0.7; margin-top: 4px; }
      .bm-panel { margin-top: 12px; }
      .bm-count { font-size: 15px; margin-bottom: 12px; }
      .bm-big { font-size: 28px; font-weight: 600; color: var(--bm-green); }
      .bm-big2 { font-size: 20px; font-weight: 600; }
      .bm-search { width: 100%; max-width: 420px; }
      .bm-cat { border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-cat-head { display: flex; align-items: center; gap: 8px; padding: 8px 0; cursor: pointer; user-select: none; }
      .bm-cat-head:hover { opacity: 0.85; }
      .bm-cat-name { font-weight: 600; }
      .bm-cat-count { margin-left: 6px; font-size: 12px; opacity: 0.6; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); border-radius: 999px; padding: 1px 9px; }
      .bm-table { width: 100%; border-collapse: collapse; margin: 0 0 6px 30px; }
      .bm-row-link { cursor: pointer; }
      .bm-row-link:hover td { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
      .bm-row-selected td { background: color-mix(in srgb, var(--bm-green) 12%, transparent); }
      .bm-table td { padding: 4px 12px 4px 0; border-top: 1px solid var(--mat-sys-outline-variant); vertical-align: top; }
      .bm-mono { font-family: monospace; }
      .bm-num { white-space: nowrap; opacity: 0.7; font-size: 12.5px; }
      .bm-dim { opacity: 0.6; }
      .bm-src { font-size: 11px; padding: 1px 8px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
      .bm-expand-row td { padding: 0; }
      .bm-detail { padding: 10px 14px 14px 30px; }
      .bm-detail h4 { margin: 14px 0 6px; font-size: 13px; opacity: 0.8; }
      .bm-md :first-child { margin-top: 0; }
      .bm-opts { width: 100%; border-collapse: collapse; }
      .bm-opts th { text-align: left; opacity: 0.6; font-weight: 500; padding: 3px 12px 3px 0; font-size: 12px; }
      .bm-opts td { padding: 3px 12px 3px 0; border-top: 1px solid var(--mat-sys-outline-variant); font-size: 13px; }
      .bm-code { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); border-radius: 8px; padding: 10px 12px; overflow-x: auto; font-size: 12px; }
    `,
  ],
})
export class ChecksCatalogComponent implements OnInit {
  private checkService = inject(CheckService);
  private sanitizer = inject(DomSanitizer);
  checks = signal<CheckCatalogEntry[]>([]);
  loading = signal(true);
  query = signal('');
  openCats = signal<Set<string>>(new Set());
  expanded = signal<string | null>(null);
  detail = signal<CheckDetail | null>(null);

  private filtered = computed(() => {
    const q = this.query().trim().toLowerCase();
    if (!q) return this.checks();
    return this.checks().filter(
      (c) => c.name.toLowerCase().includes(q) || (c.short_description || '').toLowerCase().includes(q),
    );
  });

  groups = computed<CategoryGroup[]>(() => {
    const by = new Map<string, CheckCatalogEntry[]>();
    for (const c of this.filtered()) {
      const cat = c.category || 'Other';
      (by.get(cat) ?? by.set(cat, []).get(cat)!).push(c);
    }
    return [...by.entries()]
      .map(([name, checks]) => ({ name, checks: checks.sort((a, b) => a.name.localeCompare(b.name)) }))
      .sort((a, b) => a.name.localeCompare(b.name));
  });

  descriptionHtml = computed<SafeHtml>(() => {
    const md = (this.detail()?.metadata?.['description'] as string) || '_No detailed description yet — the describe pass fills this in._';
    return this.sanitizer.bypassSecurityTrustHtml(marked.parse(md) as string);
  });

  ngOnInit(): void {
    this.reload();
  }

  reload(): void {
    this.loading.set(true);
    this.checkService.listChecks().subscribe({
      next: (r) => { this.checks.set(r.checks); this.loading.set(false); },
      error: () => this.loading.set(false),
    });
  }

  toggleCat(name: string): void {
    this.openCats.update((s) => {
      const next = new Set(s);
      next.has(name) ? next.delete(name) : next.add(name);
      return next;
    });
  }

  isCatOpen(name: string): boolean {
    // When filtering, auto-open every category so matches are visible.
    return this.query().trim() !== '' || this.openCats().has(name);
  }

  toggle(c: CheckCatalogEntry): void {
    if (this.expanded() === c.name) {
      this.expanded.set(null);
      return;
    }
    this.expanded.set(c.name);
    this.detail.set(null);
    this.checkService.getCheck(c.name).subscribe((d) => {
      if (this.expanded() === c.name) this.detail.set(d);
    });
  }

  optionCount(c: CheckCatalogEntry): number {
    return Object.keys(c.options || {}).length;
  }

  optionRows(d: CheckDetail): { key: string; spec: CheckOption }[] {
    const opts = (d.metadata?.['options'] as Record<string, CheckOption>) || {};
    return Object.entries(opts).map(([key, spec]) => ({ key, spec }));
  }
}
