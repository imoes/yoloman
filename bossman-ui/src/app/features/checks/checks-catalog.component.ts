import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { CheckCatalogEntry } from '../../core/models/check.model';
import { CheckService } from '../../core/services/check.service';

/** The check library browser (Block G9): every check in checks.d — Checkmk
 * checks translated to read-only Starlark, plus custom checks. Shows the
 * live translated count (this is what climbs while the translation batch
 * runs — separate from the Ansible Modules page) and a searchable catalog.
 * Assigning a check to a host/group/OU happens on the host Checks tab and in
 * OU / Policy; this page is the catalog + progress view. */
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
        Starlark, plus custom checks. Assign them on a host's Checks tab or in OU / Policy.
      </p>

      <mat-card class="bm-panel">
        <mat-card-content>
          <div class="bm-count">
            <span class="bm-big">{{ checks().length }}</span> checks in the library
            @if (loading()) { <span class="bm-dim">— loading…</span> }
          </div>
          <mat-form-field appearance="outline" class="bm-search">
            <mat-icon matPrefix>search</mat-icon>
            <mat-label>Filter checks</mat-label>
            <input matInput [(ngModel)]="query" placeholder="name or description" />
          </mat-form-field>

          @if (filtered().length) {
            <table class="bm-table">
              <thead><tr><th>Check</th><th>Description</th><th>Params</th><th>Source</th></tr></thead>
              <tbody>
                @for (c of filtered(); track c.name) {
                  <tr>
                    <td class="bm-mono">{{ c.name }}</td>
                    <td class="bm-dim">{{ c.short_description }}</td>
                    <td>{{ optionCount(c) }}</td>
                    <td><span class="bm-src">{{ c.source }}</span></td>
                  </tr>
                }
              </tbody>
            </table>
          } @else if (!loading()) {
            <p class="bm-dim">
              @if (checks().length) { No checks match “{{ query() }}”. }
              @else { No checks yet — the translation batch fills checks.d as it runs. }
            </p>
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
      .bm-search { width: 100%; max-width: 420px; }
      .bm-table { width: 100%; border-collapse: collapse; }
      .bm-table th { text-align: left; opacity: 0.6; font-weight: 500; padding: 4px 12px 4px 0; }
      .bm-table td { padding: 5px 12px 5px 0; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-mono { font-family: monospace; }
      .bm-dim { opacity: 0.6; }
      .bm-src { font-size: 11px; padding: 1px 8px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
    `,
  ],
})
export class ChecksCatalogComponent implements OnInit {
  private checkService = inject(CheckService);
  checks = signal<CheckCatalogEntry[]>([]);
  loading = signal(true);
  query = signal('');

  filtered = computed(() => {
    const q = this.query().trim().toLowerCase();
    if (!q) return this.checks();
    return this.checks().filter(
      (c) => c.name.toLowerCase().includes(q) || (c.short_description || '').toLowerCase().includes(q),
    );
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

  optionCount(c: CheckCatalogEntry): number {
    return Object.keys(c.options || {}).length;
  }
}
