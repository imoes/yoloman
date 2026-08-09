import { Component, Inject, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { CheckCatalogEntry, CheckOption } from '../../../core/models/check.model';
import { CheckService } from '../../../core/services/check.service';
import { ConditionsEditorComponent } from '../conditions-editor/conditions-editor.component';

export interface CheckAssignDialogData {
  scopeLabel: string; // e.g. "OU /Databases" or "group web-servers"
}

export interface CheckAssignResult {
  check_name: string;
  parameters: Record<string, unknown>;
  conditions: Record<string, unknown>;
}

/** Pick a library check and fill its parameters, to assign it to an OU/group/
 * site (GPO-style, Block G9-P3). Miller-style browser: a searchable list where
 * each check shows its name with its description in smaller text underneath
 * (design philosophy), and the selected check's parameters render as compact
 * fields on the right. */
@Component({
  selector: 'app-check-assign-dialog',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatButtonModule, ConditionsEditorComponent],
  template: `
    <h2 mat-dialog-title>Assign a check to {{ data.scopeLabel }}</h2>
    <mat-dialog-content>
      <input class="bm-in bm-search" type="search" placeholder="Search checks…"
             [ngModel]="search()" (ngModelChange)="search.set($event)" />
      <div class="bm-browser">
        <!-- Miller column 1: category -->
        <div class="bm-cats">
          @for (g of grouped(); track g.category) {
            <div class="bm-cat" [class.sel]="effectiveCat() === g.category" (click)="activeCat.set(g.category)">
              <span class="bm-cat-lbl">{{ g.category }}</span><span class="bm-cat-n">{{ g.items.length }}</span>
            </div>
          } @empty { <p class="bm-dim">No checks match.</p> }
        </div>
        <!-- Miller column 2: checks with full names + descriptions -->
        <div class="bm-list">
          @for (c of catItems(); track c.name) {
            <div class="bm-item" [class.sel]="pick() === c.name" (click)="onPick(c.name)" [title]="c.name">
              <div class="bm-item-name">{{ label(c) }}</div>
              <div class="bm-item-key">{{ c.name }}</div>
              @if (c.short_description) { <div class="bm-item-desc">{{ c.short_description }}</div> }
            </div>
          } @empty { <p class="bm-dim">Pick a category.</p> }
        </div>
        <div class="bm-params">
          @if (pick(); as p) {
            <div class="bm-params-head">{{ label(picked()!) }} <span class="bm-params-key">{{ p }}</span></div>
            @if (fullDesc()) { <pre class="bm-params-desc">{{ fullDesc() }}</pre> }
            @for (o of options(); track o.key) {
              <div class="bm-field">
                <label>{{ o.key }}{{ o.spec.required ? ' *' : '' }}</label>
                <input class="bm-in" [ngModel]="draft()[o.key]" (ngModelChange)="setDraft(o.key, $event)"
                       [placeholder]="o.spec.type || ''" />
                @if (o.spec.description) { <p class="bm-field-hint">{{ o.spec.description }}</p> }
              </div>
            } @empty { <p class="bm-dim">This check has no parameters — assign it as-is.</p> }
          } @else { <p class="bm-dim">Pick a check on the left.</p> }
        </div>
      </div>
      <app-conditions-editor [conditions]="conditions()" (conditionsChange)="conditions.set($event)" />
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="!pick()" (click)="save()">Assign</button>
    </mat-dialog-actions>
  `,
  styles: [`
    .bm-search { max-width: 100%; margin-bottom: 10px; }
    .bm-browser { display: flex; gap: 12px; min-width: 680px; }
    .bm-cats { flex: 0 0 170px; max-height: 380px; overflow-y: auto; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 4px; }
    .bm-cat { display: flex; align-items: center; gap: 6px; padding: 6px 8px; border-radius: 6px; cursor: pointer; font-size: 13px; }
    .bm-cat:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-cat.sel { background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
    .bm-cat-lbl { flex: 1; } .bm-cat-n { font-size: 11px; opacity: 0.5; }
    .bm-list { flex: 0 0 240px; max-height: 380px; overflow-y: auto; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; }
    .bm-item { padding: 6px 10px; cursor: pointer; border-left: 3px solid transparent; }
    .bm-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-item.sel { border-left-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
    .bm-item-name { font-size: 13px; font-weight: 600; }
    .bm-item-key { font-size: 11px; font-family: ui-monospace, monospace; opacity: 0.5; }
    .bm-item-desc { font-size: 11.5px; opacity: 0.6; line-height: 1.35; margin-top: 1px; }
    .bm-params { flex: 1 1 280px; min-width: 0; max-height: 380px; overflow-y: auto; }
    .bm-params-head { font-size: 14px; font-weight: 600; margin-bottom: 6px; }
    .bm-params-key { font-family: ui-monospace, monospace; font-size: 12px; opacity: 0.5; font-weight: 400; }
    .bm-params-desc { font-size: 11.5px; white-space: pre-wrap; opacity: 0.75; line-height: 1.4; margin: 4px 0 10px; max-height: 140px; overflow-y: auto; }
    .bm-dim { opacity: 0.7; font-size: 13px; padding: 6px 2px; }
  `],
})
export class CheckAssignDialogComponent implements OnInit {
  dialogRef = inject(MatDialogRef<CheckAssignDialogComponent, CheckAssignResult>);
  private checkService = inject(CheckService);
  catalog = signal<CheckCatalogEntry[]>([]);
  pick = signal<string>('');
  draft = signal<Record<string, string>>({});
  search = signal<string>('');
  conditions = signal<Record<string, unknown>>({});
  activeCat = signal<string>('');
  fullDesc = signal<string>('');

  /** Human name from the Checkmk service template (e.g. "Capacity %s" → "Capacity"),
   * falling back to a title-cased package name. Mirrors the host add-check dialog. */
  label(c: CheckCatalogEntry): string {
    const d = (c.short_description || '').replace(/%s/g, '').replace(/\s+/g, ' ').trim();
    return d || c.name.replace(/_/g, ' ').replace(/\b\w/g, (m) => m.toUpperCase());
  }

  private filtered = computed<CheckCatalogEntry[]>(() => {
    const q = this.search().trim().toLowerCase();
    const all = this.catalog();
    if (!q) return all;
    return all.filter((c) => c.name.toLowerCase().includes(q)
      || this.label(c).toLowerCase().includes(q) || (c.short_description || '').toLowerCase().includes(q));
  });

  grouped = computed(() => {
    const groups = new Map<string, CheckCatalogEntry[]>();
    for (const c of this.filtered()) {
      const cat = c.category || 'Other';
      (groups.get(cat) ?? groups.set(cat, []).get(cat)!).push(c);
    }
    return [...groups.entries()]
      .map(([category, items]) => ({ category, items: items.sort((a, b) => this.label(a).localeCompare(this.label(b))) }))
      .sort((a, b) => a.category.localeCompare(b.category));
  });
  effectiveCat = computed(() => {
    const cats = this.grouped();
    return cats.some((c) => c.category === this.activeCat()) ? this.activeCat() : (cats[0]?.category ?? '');
  });
  catItems = computed(() => this.grouped().find((c) => c.category === this.effectiveCat())?.items ?? []);
  picked = computed(() => this.catalog().find((x) => x.name === this.pick()) ?? null);

  options = computed<{ key: string; spec: CheckOption }[]>(() => {
    const c = this.catalog().find((x) => x.name === this.pick());
    return c ? Object.entries(c.options || {}).map(([key, spec]) => ({ key, spec })) : [];
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: CheckAssignDialogData) {}

  ngOnInit(): void {
    this.checkService.listChecks().subscribe((r) => this.catalog.set(r.checks));
  }

  onPick(name: string): void {
    this.pick.set(name);
    const c = this.catalog().find((x) => x.name === name);
    const d: Record<string, string> = {};
    for (const [k, spec] of Object.entries(c?.options || {})) {
      if (spec.default !== undefined && spec.default !== null) d[k] = String(spec.default);
    }
    this.draft.set(d);
    // Load the full "what this check does" description for the detail pane.
    this.fullDesc.set('');
    this.checkService.getCheck(name).subscribe({
      next: (r) => this.fullDesc.set((r as { metadata?: { description?: string } })?.metadata?.description
        || c?.summary || c?.short_description || ''),
      error: () => this.fullDesc.set(c?.short_description || ''),
    });
  }

  setDraft(key: string, value: string): void {
    this.draft.update((d) => ({ ...d, [key]: value }));
  }

  private typedParams(): Record<string, unknown> {
    const c = this.catalog().find((x) => x.name === this.pick());
    const opts = c?.options || {};
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(this.draft())) {
      if (v === '' || v == null) continue;
      const t = (opts[k]?.type || '').toLowerCase();
      if (t === 'int' || t === 'integer') out[k] = parseInt(v, 10);
      else if (t === 'float' || t === 'number') out[k] = parseFloat(v);
      else if (t === 'bool' || t === 'boolean') out[k] = v === 'true' || v === '1' || v === 'yes';
      else out[k] = v;
    }
    return out;
  }

  save(): void {
    if (!this.pick()) return;
    this.dialogRef.close({ check_name: this.pick(), parameters: this.typedParams(), conditions: this.conditions() });
  }
}
