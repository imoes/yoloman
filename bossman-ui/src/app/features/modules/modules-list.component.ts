import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatButtonToggleModule } from '@angular/material/button-toggle';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatIconModule } from '@angular/material/icon';
import { ModuleService } from '../../core/services/module.service';
import { ModuleCatalog, ModuleDetail, ModuleInfo, ModuleOptionSpec } from '../../core/models/module.model';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { PerfOMeterComponent } from '../../shared/components/perf-o-meter/perf-o-meter.component';

/** The module library browser (Block H4) — the management surface for the
 * Starlark collection modules (docs/plan.md Blocks G7/G8): per-collection
 * translation progress, a searchable catalog, and per-module detail
 * (argspec + the stored Starlark source). Read-only by design: the
 * library is written exclusively through the validated submit_module MCP
 * pipeline. */
@Component({
  selector: 'app-modules-list',
  standalone: true,
  imports: [
    FormsModule,
    MatCardModule,
    MatButtonToggleModule,
    MatFormFieldModule,
    MatInputModule,
    MatIconModule,
    HostStatusBadgeComponent,
    PerfOMeterComponent,
  ],
  template: `
    <div class="bm-page">
      <h1>Modules</h1>
      <p class="bm-subtitle">
        The agent's vocabulary: the <code>built-in</code> modules run native in Go, the collections run
        as sandboxed Starlark modules — held centrally by Bossman, pulled by Duppys on demand.
      </p>

      @if (catalog(); as cat) {
        <div class="bm-collection-row">
          <mat-card class="bm-collection-card bm-collection-card--builtin">
            <div class="bm-collection-name">built-in</div>
            <div class="bm-collection-count">52 native Go modules</div>
            <app-perf-o-meter [value]="100" unit="%" />
          </mat-card>
          @for (entry of collectionEntries(); track entry.name) {
            <mat-card class="bm-collection-card">
              <div class="bm-collection-name">{{ entry.name }}</div>
              <div class="bm-collection-count">{{ entry.translated }} / {{ entry.total }} translated</div>
              <app-perf-o-meter [value]="(entry.translated / entry.total) * 100" unit="%" />
            </mat-card>
          }
        </div>

        <div class="bm-toolbar">
          <mat-form-field appearance="outline" class="bm-search">
            <mat-label>Search modules</mat-label>
            <input matInput [(ngModel)]="search" placeholder="docker_container, sysctl, x509…" />
          </mat-form-field>
          <mat-button-toggle-group [value]="filter()" (change)="filter.set($event.value)">
            <mat-button-toggle value="all">All ({{ cat.total }})</mat-button-toggle>
            <mat-button-toggle value="translated">Translated ({{ cat.translated }})</mat-button-toggle>
            <mat-button-toggle value="pending">Pending ({{ cat.total - cat.translated }})</mat-button-toggle>
          </mat-button-toggle-group>
        </div>

        <table class="bm-table">
          <thead>
            <tr>
              <th>Module</th>
              <th>Collection</th>
              <th>Status</th>
              <th>Mode</th>
              <th>Description</th>
            </tr>
          </thead>
          <tbody>
            @for (m of visibleModules(); track m.fqcn) {
              <tr class="bm-row-link" [class.bm-row-selected]="expanded() === m.fqcn" (click)="toggle(m)">
                <td class="bm-mono">{{ m.name }}</td>
                <td class="bm-dim">{{ m.collection }}</td>
                <td>
                  <app-status-badge
                    [status]="m.translated ? 'ok' : 'unknown'"
                    [label]="m.translated ? 'translated' : 'pending'"
                  />
                </td>
                <td>
                  @if (m.translated) {
                    <span class="bm-chip" [class.bm-chip--write]="m.writes">{{ m.writes ? 'write' : 'read-only' }}</span>
                  }
                </td>
                <td class="bm-desc">{{ m.short_description || '' }}</td>
              </tr>
              @if (expanded() === m.fqcn) {
                <tr class="bm-expand-row">
                  <td colspan="5">
                    @if (detail(); as d) {
                      <div class="bm-detail">
                        @if (d.metadata.short_description) {
                          <p class="bm-detail-desc">{{ d.metadata.short_description }}</p>
                        }
                        @if (optionRows(d).length) {
                          <h4>Options</h4>
                          <table class="bm-options-table">
                            <thead>
                              <tr><th>Option</th><th>Type</th><th>Required</th><th>Default</th><th>Choices</th><th>Description</th></tr>
                            </thead>
                            <tbody>
                              @for (o of optionRows(d); track o.name) {
                                <tr>
                                  <td class="bm-mono">{{ o.name }}</td>
                                  <td>{{ o.spec.type || 'str' }}</td>
                                  <td>{{ o.spec.required ? 'yes' : '' }}</td>
                                  <td class="bm-mono">{{ formatValue(o.spec.default) }}</td>
                                  <td class="bm-mono">{{ formatValue(o.spec.choices) }}</td>
                                  <td class="bm-desc">{{ formatDescription(o.spec.description) }}</td>
                                </tr>
                              }
                            </tbody>
                          </table>
                        }
                        @if (d.star_code) {
                          <h4>Starlark source</h4>
                          <pre class="bm-source">{{ d.star_code }}</pre>
                        } @else {
                          <p class="bm-empty">Not translated yet — queued for the translation pipeline.</p>
                        }
                      </div>
                    } @else {
                      <p class="bm-empty">Loading…</p>
                    }
                  </td>
                </tr>
              }
            }
          </tbody>
        </table>
      } @else {
        <p class="bm-empty">Loading module catalog…</p>
      }
    </div>
  `,
  styles: [
    `
      .bm-page {
        padding: 24px;
        max-width: 1200px;
        margin: 0 auto;
      }
      .bm-subtitle {
        opacity: 0.7;
        margin-top: -8px;
        margin-bottom: 20px;
      }
      .bm-collection-row {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
        gap: 12px;
        margin-bottom: 20px;
      }
      .bm-collection-card {
        padding: 16px;
        display: flex;
        flex-direction: column;
        gap: 8px;
      }
      .bm-collection-card--builtin {
        border-left: 3px solid var(--bm-green);
      }
      .bm-collection-name {
        font-family: monospace;
        font-weight: 600;
      }
      .bm-collection-count {
        font-size: 12px;
        opacity: 0.7;
      }
      .bm-toolbar {
        display: flex;
        align-items: center;
        gap: 16px;
        margin-bottom: 8px;
      }
      .bm-search {
        flex: 1;
        max-width: 420px;
      }
      .bm-table {
        width: 100%;
        border-collapse: collapse;
      }
      .bm-table th {
        text-align: left;
        font-size: 12px;
        opacity: 0.7;
        padding: 8px 10px;
      }
      .bm-table td {
        padding: 8px 10px;
        border-top: 1px solid var(--mat-sys-outline-variant);
      }
      .bm-row-link {
        cursor: pointer;
      }
      .bm-row-link:hover {
        background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent);
      }
      .bm-row-selected {
        background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent);
      }
      .bm-mono {
        font-family: monospace;
        font-size: 13px;
      }
      .bm-dim {
        opacity: 0.65;
      }
      .bm-desc {
        font-size: 13px;
        opacity: 0.85;
      }
      .bm-chip {
        font-size: 11px;
        padding: 2px 8px;
        border-radius: 999px;
        background: color-mix(in srgb, var(--bm-green) 22%, transparent);
      }
      .bm-chip--write {
        background: color-mix(in srgb, var(--bm-gold) 25%, transparent);
      }
      .bm-expand-row td {
        border-top: none;
        background: color-mix(in srgb, var(--mat-sys-primary) 4%, transparent);
      }
      .bm-detail {
        padding: 8px 4px 16px;
      }
      .bm-detail h4 {
        margin: 14px 0 6px;
        font-size: 12px;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        opacity: 0.7;
      }
      .bm-options-table {
        width: 100%;
        border-collapse: collapse;
        font-size: 13px;
      }
      .bm-options-table th {
        text-align: left;
        font-size: 11px;
        opacity: 0.6;
        padding: 4px 8px;
      }
      .bm-options-table td {
        padding: 4px 8px;
        border-top: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 60%, transparent);
        vertical-align: top;
      }
      .bm-source {
        max-height: 420px;
        overflow: auto;
        background: var(--bm-black);
        border: 1px solid var(--mat-sys-outline-variant);
        border-left: 3px solid var(--bm-green);
        border-radius: 6px;
        padding: 12px;
        font-size: 12.5px;
        line-height: 1.5;
      }
      .bm-empty {
        opacity: 0.6;
      }
    `,
  ],
})
export class ModulesListComponent implements OnInit {
  private moduleService = inject(ModuleService);

  catalog = signal<ModuleCatalog | null>(null);
  filter = signal<'all' | 'translated' | 'pending'>('all');
  search = '';
  expanded = signal<string | null>(null);
  detail = signal<ModuleDetail | null>(null);

  collectionEntries = computed(() => {
    const cat = this.catalog();
    if (!cat) return [];
    return Object.entries(cat.collections)
      .map(([name, v]) => ({ name, ...v }))
      .sort((a, b) => a.name.localeCompare(b.name));
  });

  visibleModules = computed(() => {
    const cat = this.catalog();
    if (!cat) return [];
    const filter = this.filter();
    const q = this.search.trim().toLowerCase();
    return cat.modules.filter((m) => {
      if (filter === 'translated' && !m.translated) return false;
      if (filter === 'pending' && m.translated) return false;
      if (q && !m.fqcn.toLowerCase().includes(q) && !(m.short_description ?? '').toLowerCase().includes(q)) return false;
      return true;
    });
  });

  ngOnInit(): void {
    this.moduleService.catalog().subscribe((cat) => this.catalog.set(cat));
  }

  toggle(m: ModuleInfo): void {
    if (this.expanded() === m.fqcn) {
      this.expanded.set(null);
      return;
    }
    this.expanded.set(m.fqcn);
    this.detail.set(null);
    this.moduleService.detail(m.fqcn).subscribe((d) => this.detail.set(d));
  }

  optionRows(d: ModuleDetail): { name: string; spec: ModuleOptionSpec }[] {
    return Object.entries(d.metadata.options ?? {}).map(([name, spec]) => ({ name, spec }));
  }

  formatValue(v: unknown): string {
    if (v === undefined || v === null) return '';
    if (Array.isArray(v)) return v.join(', ');
    return String(v);
  }

  formatDescription(d: string | string[] | undefined): string {
    if (!d) return '';
    return Array.isArray(d) ? d.join(' ') : d;
  }
}
