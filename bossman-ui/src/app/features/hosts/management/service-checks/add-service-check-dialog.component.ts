import { Component, Inject, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { CheckService } from '../../../../core/services/check.service';
import { CheckCatalogEntry, CheckOption } from '../../../../core/models/check.model';
import { ParamFormComponent } from '../../../../shared/param-form/param-form.component';
import { ParamSchema, ParamSpec } from '../../../../shared/param-form/param-form.types';

export interface AddServiceCheckData {
  agentId: string;
  hostName: string;
  /** When set, the dialog edits an existing assignment in place instead of
   * adding a new one: it skips the catalog browser, pre-fills the param form
   * from the current parameters, and saves via PATCH. */
  edit?: { assignmentId: string; checkName: string; parameters: Record<string, unknown> };
}

// Category column order for the check browser (Service checks first).
const CHECK_CAT_ORDER = [
  'Service checks', 'Network', 'Applications', 'Database', 'Storage',
  'Operating System', 'Security', 'Virtualization & Cloud',
  'Environment & Power', 'Hardware & Sensors', 'Other',
];
const CHECK_CAT_ICON: Record<string, string> = {
  'Service checks': 'network_check', Network: 'lan', Applications: 'apps', Database: 'storage',
  Storage: 'save', 'Operating System': 'settings', Security: 'security',
  'Virtualization & Cloud': 'cloud', 'Environment & Power': 'bolt', 'Hardware & Sensors': 'memory',
  Other: 'folder',
};

/** Configure & assign an active service check to a host — the same
 * catalog→form→assign flow as the Roles & Features wizard, reusing app-param-form
 * over the check's typed `options`. */
@Component({
  selector: 'app-add-service-check-dialog',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatButtonModule, MatIconModule, ParamFormComponent],
  template: `
    <h2 mat-dialog-title>{{ data.edit ? 'Edit service check' : 'Add a service check' }} <span class="bm-dim">on {{ data.hostName }}</span></h2>
    <mat-dialog-content class="bm-sc-body">
      @if (!picked()) {
        <input class="bm-sc-search" placeholder="Search checks…" [ngModel]="query()" (ngModelChange)="query.set($event)" />
        <!-- Miller columns: category → checks (with description) → detail -->
        <div class="bm-sc-miller">
          <div class="bm-sc-col bm-sc-cats">
            @for (c of catsOrdered(); track c.category) {
              <div class="bm-sc-cat" [class.bm-sc-sel]="effectiveCat() === c.category" (click)="activeCat.set(c.category)">
                <mat-icon class="bm-sc-cat-ic">{{ catIcon(c.category) }}</mat-icon>
                <span class="bm-sc-cat-lbl">{{ c.category }}</span>
                <span class="bm-sc-count">{{ c.items.length }}</span>
              </div>
            } @empty { <p class="bm-dim bm-sc-pad">No checks match.</p> }
          </div>
          <div class="bm-sc-col bm-sc-checks">
            @for (c of catItems(); track c.name) {
              <div class="bm-sc-item" [class.bm-sc-sel]="focus() === c.name" (click)="pick(c)" (mouseenter)="setFocus(c)">
                <div class="bm-sc-label">{{ label(c) }} <span class="bm-sc-key">· {{ c.name }}</span></div>
                <div class="bm-sc-desc">{{ c.short_description || c.summary || '' }}</div>
              </div>
            } @empty { <p class="bm-dim bm-sc-pad">Pick a category.</p> }
          </div>
          <aside class="bm-sc-col bm-sc-detail">
            @if (focused(); as c) {
              <div class="bm-sc-label">{{ label(c) }}</div>
              <div class="bm-sc-key">{{ c.name }}</div>
              @if (description(c.name)) { <pre class="bm-sc-full">{{ description(c.name) }}</pre> }
              @else { <p class="bm-dim">Loading description…</p> }
              <button mat-flat-button color="primary" class="bm-sc-configure" (click)="pick(c)"><mat-icon>tune</mat-icon> Configure</button>
            } @else { <p class="bm-dim">Select a check to see what it does.</p> }
          </aside>
        </div>
      } @else {
        <div class="bm-sc-cfg-head">
          @if (!data.edit) {
            <button type="button" class="bm-sc-back" (click)="picked.set(null)"><mat-icon>arrow_back</mat-icon></button>
          }
          <div>
            <div class="bm-sc-label">{{ label(picked()!) }}</div>
            @if (picked()!.summary) { <div class="bm-sc-desc">{{ picked()!.summary }}</div> }
          </div>
        </div>
        <app-param-form [params]="schema()" [initial]="initial()" (valuesChange)="values.set($event)" />
      }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button mat-dialog-close>Cancel</button>
      @if (picked()) {
        <button mat-flat-button color="primary" [disabled]="!canSave() || saving()" (click)="save()">
          <mat-icon>{{ data.edit ? 'save' : 'add_task' }}</mat-icon>
          {{ saving() ? 'Saving…' : (data.edit ? 'Save changes' : 'Add check') }}
        </button>
      }
    </mat-dialog-actions>
  `,
  styles: [`
    .bm-dim { opacity: 0.6; font-weight: 400; }
    .bm-sc-body { min-width: 720px; max-width: 900px; }
    .bm-sc-search { width: 100%; box-sizing: border-box; padding: 8px 11px; margin-bottom: 10px; border-radius: 6px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; }
    .bm-sc-miller { display: grid; grid-template-columns: 200px 1fr 260px; gap: 10px; height: 46vh; }
    .bm-sc-col { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow-y: auto; padding: 5px; min-width: 0; }
    .bm-sc-pad { padding: 10px; }
    .bm-sc-cat { display: flex; align-items: center; gap: 7px; padding: 6px 8px; border-radius: 6px; cursor: pointer; font-size: 13px; }
    .bm-sc-cat:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-sc-cat-ic { font-size: 17px; width: 17px; height: 17px; opacity: 0.75; }
    .bm-sc-cat-lbl { flex: 1; }
    .bm-sc-count { font-size: 11px; opacity: 0.5; }
    .bm-sc-sel { background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
    .bm-sc-item { text-align: left; border-radius: 6px; padding: 7px 9px; cursor: pointer; color: inherit; }
    .bm-sc-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-sc-label { font-size: 13px; font-weight: 600; }
    .bm-sc-key { opacity: 0.5; font-weight: 400; font-size: 12px; }
    .bm-sc-desc { font-size: 11.5px; opacity: 0.62; margin-top: 2px; line-height: 1.35;
      display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
    .bm-sc-detail { padding: 12px; }
    .bm-sc-full { font-size: 11.5px; white-space: pre-wrap; opacity: 0.8; line-height: 1.4; margin: 8px 0; max-height: 30vh; overflow-y: auto; }
    .bm-sc-configure { margin-top: 8px; }
    .bm-sc-cfg-head { display: flex; align-items: flex-start; gap: 8px; margin-bottom: 12px; }
    .bm-sc-back { background: none; border: none; color: inherit; cursor: pointer; opacity: 0.7; padding: 2px; }
  `],
})
export class AddServiceCheckDialogComponent {
  private checkService = inject(CheckService);
  private ref = inject(MatDialogRef<AddServiceCheckDialogComponent>);

  private catalog = signal<CheckCatalogEntry[]>([]);
  query = signal('');
  activeCat = signal<string>('');
  focus = signal<string>('');
  private descriptions = signal<Record<string, string>>({});
  picked = signal<CheckCatalogEntry | null>(null);
  values = signal<Record<string, unknown>>({});
  saving = signal(false);

  /** All catalog checks matching the search, grouped by category, ordered. */
  private grouped = computed(() => {
    const q = this.query().trim().toLowerCase();
    const groups = new Map<string, CheckCatalogEntry[]>();
    for (const c of this.catalog()) {
      if (q && !c.name.toLowerCase().includes(q) && !this.label(c).toLowerCase().includes(q)
          && !(c.short_description || '').toLowerCase().includes(q) && !(c.summary || '').toLowerCase().includes(q)) continue;
      const cat = c.category || 'Other';
      (groups.get(cat) ?? groups.set(cat, []).get(cat)!).push(c);
    }
    return [...groups.entries()]
      .map(([category, items]) => ({ category, items: items.sort((a, b) => this.label(a).localeCompare(this.label(b))) }))
      .sort((a, b) => {
        const ia = CHECK_CAT_ORDER.indexOf(a.category), ib = CHECK_CAT_ORDER.indexOf(b.category);
        return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib) || a.category.localeCompare(b.category);
      });
  });
  catsOrdered = computed(() => this.grouped());
  effectiveCat = computed(() => {
    const cats = this.catsOrdered();
    return cats.some((c) => c.category === this.activeCat()) ? this.activeCat() : (cats[0]?.category ?? '');
  });
  catItems = computed(() => this.catsOrdered().find((c) => c.category === this.effectiveCat())?.items ?? []);
  focused = computed(() => this.catalog().find((c) => c.name === this.focus()) ?? null);
  catIcon(c: string): string { return CHECK_CAT_ICON[c] ?? 'folder'; }
  description(name: string): string { return this.descriptions()[name] ?? ''; }

  setFocus(c: CheckCatalogEntry): void {
    this.focus.set(c.name);
    if (this.descriptions()[c.name] === undefined) {
      this.descriptions.update((m) => ({ ...m, [c.name]: '' }));
      this.checkService.getCheck(c.name).subscribe({
        next: (r) => {
          const desc = (r as { metadata?: { description?: string } })?.metadata?.description || c.summary || c.short_description || 'No description available.';
          this.descriptions.update((m) => ({ ...m, [c.name]: desc }));
        },
        error: () => this.descriptions.update((m) => ({ ...m, [c.name]: c.summary || 'Could not load description.' })),
      });
    }
  }

  // The check's options → the param-form schema (choices→enum, type normalised).
  schema = computed<ParamSchema>(() => {
    const opts = this.picked()?.options ?? {};
    const out: ParamSchema = {};
    for (const [key, o] of Object.entries(opts as Record<string, CheckOption>)) {
      out[key] = this.toSpec(o);
    }
    return out;
  });
  initial = computed<Record<string, unknown>>(() => {
    const ed = this.data.edit;
    if (ed && this.picked()?.name === ed.checkName) return { ...ed.parameters };
    return { service_name: this.picked() ? this.label(this.picked()!) : '' };
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: AddServiceCheckData) {
    // The host-assignable catalog, browsed by category in the Miller columns
    // ('Service checks' first). SNMP checks (datasource 'snmp') are excluded —
    // those are configured against a monitored device in the SNMP Devices flow,
    // not per host. Grouping/sorting happens in `grouped()`.
    this.checkService.listChecks().subscribe((r) => {
      // Exclude SNMP checks (configured on a device, not a host) and unrunnable
      // ones (mistranslations that wrap Checkmk-internal data — they can never
      // produce results on this agent, so offering them is misleading).
      const checks = (r.checks || []).filter((c) => c.datasource !== 'snmp' && c.runnable !== false);
      this.catalog.set(checks);
      // Edit mode: jump straight to the pre-filled form for the edited check.
      const ed = this.data.edit;
      if (ed) {
        const c = checks.find((x) => x.name === ed.checkName);
        if (c) this.picked.set(c);
      }
    });
  }

  private toSpec(o: CheckOption): ParamSpec {
    const t = (o.type || 'string') as string;
    const type = (t === 'boolean' ? 'bool' : t) as ParamSpec['type'];
    const choices = (o as CheckOption & { enum?: unknown[] }).enum ?? o.choices;
    return {
      type: (['string', 'number', 'bool', 'list', 'object'].includes(type) ? type : 'string') as ParamSpec['type'],
      description: o.description,
      default: o.default,
      required: o.required,
      secret: (o as CheckOption & { secret?: boolean }).secret,
      enum: choices as unknown[] | undefined,
    };
  }

  label(c: CheckCatalogEntry): string {
    const d = (c.short_description || '').replace(/%s/g, '').replace(/\s+/g, ' ').trim();
    return d || c.name.replace(/_/g, ' ').replace(/\b\w/g, (m) => m.toUpperCase());
  }

  pick(c: CheckCatalogEntry): void { this.picked.set(c); this.values.set({}); }

  canSave(): boolean {
    const sn = (this.values()['service_name'] ?? this.initial()['service_name']) as string;
    return !!this.picked() && !!(sn && String(sn).trim());
  }

  save(): void {
    const check = this.picked();
    if (!check || this.saving()) return;
    this.saving.set(true);
    const parameters = { ...this.initial(), ...this.values() };
    const ed = this.data.edit;
    const req = ed
      ? this.checkService.updateAssignment(ed.assignmentId, parameters)
      : this.checkService.createAssignment({
          check_name: check.name, scope_type: 'host', agent_id: this.data.agentId, parameters, source: 'manual',
        });
    req.subscribe({
      next: () => this.ref.close(true),
      error: () => this.saving.set(false),
    });
  }
}
