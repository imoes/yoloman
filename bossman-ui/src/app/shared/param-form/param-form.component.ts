import { Component, OnInit, computed, input, output, signal } from '@angular/core';
import { NgTemplateOutlet } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { ParamSchema, ParamSpec } from './param-form.types';
import { FilePickerComponent } from '../components/file-picker/file-picker.component';

interface Field { key: string; spec: ParamSpec; }

/** Generic input mask rendered from a typed parameter schema (nt_runbook
 * parameters). Each field shows its description and its default value; required/
 * default-less fields are essential, the rest hide behind an "Advanced" toggle.
 * Handles string/number/bool/enum/secret, string-lists and list-of-objects
 * (inline table editor). The wizard and any runbook-run dialog reuse it. */
@Component({
  selector: 'app-param-form',
  standalone: true,
  imports: [NgTemplateOutlet, FormsModule, MatIconModule, FilePickerComponent],
  template: `
    @for (f of essential(); track f.key) {
      <ng-container [ngTemplateOutlet]="field" [ngTemplateOutletContext]="{ $implicit: f }" />
    }
    @if (advanced().length) {
      <button type="button" class="bm-pf-adv" (click)="showAdvanced.set(!showAdvanced())">
        <mat-icon>{{ showAdvanced() ? 'expand_less' : 'expand_more' }}</mat-icon>
        Advanced ({{ advanced().length }})
      </button>
      @if (showAdvanced()) {
        @for (f of advanced(); track f.key) {
          <ng-container [ngTemplateOutlet]="field" [ngTemplateOutletContext]="{ $implicit: f }" />
        }
      }
    }

    <ng-template #field let-f>
      <div class="bm-pf-field">
        <label class="bm-pf-label" [title]="f.spec.description || ''">{{ label(f.key) }}@if (f.spec.required) { <span class="bm-pf-req">*</span> }</label>
        <div class="bm-pf-control">
          @switch (control(f.spec, values()[f.key])) {
            @case ('bool') {
              <label class="bm-pf-switch"><input type="checkbox" [checked]="asBool(values()[f.key])" (change)="set(f.key, $any($event.target).checked)" /> <span>{{ asBool(values()[f.key]) ? 'yes' : 'no' }}</span></label>
            }
            @case ('enum') {
              <select class="bm-pf-in" [ngModel]="values()[f.key]" (ngModelChange)="set(f.key, $event)">
                @for (o of f.spec.enum; track o) { <option [value]="o">{{ o }}</option> }
              </select>
            }
            @case ('number') {
              <input class="bm-pf-in" type="number" [value]="values()[f.key] ?? ''" (input)="set(f.key, num($any($event.target).value))" />
            }
            @case ('secret') {
              <input class="bm-pf-in" type="password" [value]="values()[f.key] ?? ''" (input)="set(f.key, $any($event.target).value)" />
            }
            @case ('file') {
              @if (agentId()) {
                <app-file-picker [agentId]="agentId()" [value]="asStr(values()[f.key])" (valueChange)="set(f.key, $event)" [pattern]="f.spec.pattern || ''" />
              } @else {
                <input class="bm-pf-in" [value]="values()[f.key] ?? ''" (input)="set(f.key, $any($event.target).value)" />
              }
            }
            @case ('stringlist') {
              <textarea class="bm-pf-in" rows="2" [value]="joinList(values()[f.key])" (input)="set(f.key, splitList($any($event.target).value))" placeholder="one per line"></textarea>
            }
            @case ('objmap') {
              <textarea class="bm-pf-in bm-pf-json" [class.bm-pf-jsonerr]="jsonErr()[f.key]" rows="3"
                [value]="jsonDraft()[f.key] ?? objJson(values()[f.key])"
                (input)="setJson(f.key, $any($event.target).value)"
                spellcheck="false" placeholder="{ }"></textarea>
              @if (jsonErr()[f.key]) { <div class="bm-pf-jsonmsg">Invalid JSON — not saved</div> }
            }
            @case ('objlist') {
              <div class="bm-pf-tbl">
                <table>
                  <thead><tr>@for (c of colsFor(f.key, f.spec); track c) { <th>{{ c }}</th> }<th></th></tr></thead>
                  <tbody>
                    @for (row of rows(f.key); let ri = $index; track ri) {
                      <tr>
                        @for (c of colsFor(f.key, f.spec); track c) {
                          <!-- ri aliases the ROW index: inside this nested for-loop
                               the implicit index is the COLUMN index (it silently
                               wrote every edit into row 0). One-way value + input,
                               NOT ngModel, so recycled inputs don't get clobbered. -->
                          <td><input class="bm-pf-cell" [value]="row[c] ?? ''" (input)="setRow(f.key, ri, c, $any($event.target).value)" /></td>
                        }
                        <td><button type="button" class="bm-pf-x" (click)="delRow(f.key, ri)"><mat-icon>close</mat-icon></button></td>
                      </tr>
                    }
                  </tbody>
                </table>
                <button type="button" class="bm-pf-addrow" (click)="addRow(f.key, f.spec)"><mat-icon>add</mat-icon> Add row</button>
              </div>
            }
            @default {
              <input class="bm-pf-in" [value]="values()[f.key] ?? ''" (input)="set(f.key, $any($event.target).value)" />
            }
          }
        </div>
        @if (f.spec.description) { <div class="bm-pf-desc">{{ f.spec.description }}</div> }
      </div>
    </ng-template>
  `,
  styles: [`
    :host { display: block; max-width: 620px; }
    /* Compact two-column rows: label | control, description under, no Material
       outline chrome (that ate far too much vertical space). */
    .bm-pf-field { display: grid; grid-template-columns: 190px 1fr; column-gap: 14px; row-gap: 2px; align-items: center; padding: 3px 0; }
    .bm-pf-label { font-size: 12.5px; font-weight: 500; opacity: 0.85; text-align: right; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bm-pf-req { color: var(--bm-red, #c62828); margin-left: 2px; }
    .bm-pf-control { min-width: 0; }
    .bm-pf-in { width: 100%; box-sizing: border-box; font: inherit; font-size: 12.5px; padding: 4px 7px; border-radius: 5px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; }
    .bm-pf-in:focus { outline: none; border-color: var(--mat-sys-primary); }
    textarea.bm-pf-in { resize: vertical; line-height: 1.4; }
    .bm-pf-json { font-family: ui-monospace, monospace; font-size: 12px; white-space: pre; overflow-wrap: normal; overflow-x: auto; }
    .bm-pf-jsonerr { border-color: var(--bm-red, #c62828); }
    .bm-pf-jsonmsg { grid-column: 2; font-size: 11px; color: var(--bm-red, #c62828); }
    .bm-pf-switch { display: inline-flex; align-items: center; gap: 6px; font-size: 12.5px; cursor: pointer; }
    .bm-pf-switch input { accent-color: var(--mat-sys-primary); width: 15px; height: 15px; }
    .bm-pf-desc { grid-column: 2; font-size: 11.5px; opacity: 0.55; line-height: 1.35; }
    .bm-pf-adv { background: none; border: none; color: var(--mat-sys-primary); cursor: pointer; display: flex; align-items: center; gap: 4px; font-size: 12.5px; margin: 8px 0 8px 204px; }
    .bm-pf-tbl table { width: 100%; border-collapse: collapse; font-size: 12px; }
    .bm-pf-tbl th { text-align: left; opacity: 0.6; padding: 2px 6px; font-weight: 500; }
    .bm-pf-tbl td { padding: 1px 4px; border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-pf-cell { width: 100%; background: transparent; border: 1px solid var(--mat-sys-outline-variant); border-radius: 4px; color: inherit; padding: 3px 6px; box-sizing: border-box; font: inherit; font-size: 12px; }
    .bm-pf-x { background: none; border: none; color: var(--bm-red, #c62828); cursor: pointer; display: inline-flex; }
    .bm-pf-x mat-icon { font-size: 16px; width: 16px; height: 16px; }
    .bm-pf-addrow { margin-top: 5px; display: inline-flex; align-items: center; gap: 3px; font: inherit; font-size: 12px; background: none;
      border: 1px solid var(--mat-sys-outline-variant); border-radius: 5px; padding: 3px 9px; color: inherit; cursor: pointer; }
    .bm-pf-addrow mat-icon { font-size: 15px; width: 15px; height: 15px; }
  `],
})
export class ParamFormComponent implements OnInit {
  params = input.required<ParamSchema>();
  initial = input<Record<string, unknown>>({});
  agentId = input<string>('');   // required only for widget:'file' fields (remote file-picker)
  valuesChange = output<Record<string, unknown>>();

  asStr(v: unknown): string { return v == null ? '' : String(v); }

  /** Emit the prefilled defaults immediately so a consumer that never edits a
   * field still receives the full value set (the wizard runs on defaults). When
   * every field has a default (no essentials), open the list right away — an
   * empty form with just an "Advanced" toggle reads as broken. */
  ngOnInit(): void {
    this.valuesChange.emit(this.values());
    if (!this.essential().length) this.showAdvanced.set(true);
  }

  showAdvanced = signal(false);
  private overrides = signal<Record<string, unknown>>({});

  /** Some generated schemas wrap a default as `{value: X, description?}` instead
   * of a bare X (two conventions coexist in configs/config_templates). Normalize
   * to the bare scalar so `default`-based logic (prefill, essential/advanced,
   * display) works for both. Applied to a field spec and its list `items`. */
  private unwrapDefault(d: unknown): unknown {
    if (d && typeof d === 'object' && !Array.isArray(d) && 'value' in (d as Record<string, unknown>)) {
      return (d as Record<string, unknown>)['value'];
    }
    return d;
  }
  private norm(spec: ParamSpec): ParamSpec {
    const out: ParamSpec = { ...spec, default: this.unwrapDefault(spec.default) };
    if (spec.items) {
      const items: Record<string, ParamSpec> = {};
      for (const [k, v] of Object.entries(spec.items)) items[k] = this.norm(v);
      out.items = items;
    }
    return out;
  }

  /** Visible (non-hidden) fields, defaults prefilled from initial ∪ spec.default. */
  private fields = computed<Field[]>(() =>
    Object.entries(this.params())
      .filter(([, s]) => !s.hidden)
      .map(([key, spec]) => ({ key, spec: this.norm(spec) })));

  values = computed<Record<string, unknown>>(() => {
    const out: Record<string, unknown> = {};
    for (const { key, spec } of this.fields()) {
      const init = this.initial()[key];
      out[key] = init !== undefined ? init : (spec.default !== undefined ? spec.default : this.blank(spec));
    }
    return { ...out, ...this.overrides() };
  });

  essential = computed(() => this.fields().filter((f) => f.spec.required || f.spec.default === undefined));
  advanced = computed(() => this.fields().filter((f) => !(f.spec.required || f.spec.default === undefined)));

  control(spec: ParamSpec, value?: unknown): string {
    if (spec.widget === 'file') return 'file';
    if (spec.secret) return 'secret';
    if (spec.enum?.length) return 'enum';
    if (spec.type === 'bool') return 'bool';
    if (spec.type === 'number') return 'number';
    if (spec.type === 'list') {
      if (spec.items) return 'objlist';
      // Infer a table editor when the value is a list of OBJECTS even though the
      // schema didn't declare `items` (e.g. a pre-filled chrony `servers` list) —
      // otherwise joinList() would render each element as "[object Object]".
      if (Array.isArray(value) && value.some((e) => e !== null && typeof e === 'object' && !Array.isArray(e))) return 'objlist';
      return 'stringlist';
    }
    if (spec.type === 'object') return 'objmap';
    return 'text';
  }

  private blank(spec: ParamSpec): unknown {
    if (spec.type === 'bool') return false;
    if (spec.type === 'list') return [];
    if (spec.type === 'object') return {};
    if (spec.type === 'number') return null;
    return '';
  }

  label(key: string): string {
    return key.replace(/_/g, ' ').replace(/\b\w/g, (m) => m.toUpperCase());
  }
  defaultHint(spec: ParamSpec): string {
    if (spec.default === undefined || spec.default === null || spec.default === '') return '';
    if (Array.isArray(spec.default)) return spec.default.join(', ');
    // Objects are edited inline as JSON (the field already shows the value), and
    // String({}) would print "[object Object]" — so no separate default hint.
    if (typeof spec.default === 'object') return '';
    return String(spec.default);
  }

  // --- object (map) fields: edited as JSON so nested config sections work ---
  jsonDraft = signal<Record<string, string>>({});
  jsonErr = signal<Record<string, boolean>>({});
  objJson(v: unknown): string {
    if (v === undefined || v === null) return '{}';
    try { return JSON.stringify(v, null, 2); } catch { return '{}'; }
  }
  setJson(key: string, raw: string): void {
    this.jsonDraft.update((d) => ({ ...d, [key]: raw }));
    try {
      const parsed = JSON.parse(raw);
      this.jsonErr.update((e) => ({ ...e, [key]: false }));
      this.set(key, parsed);
    } catch {
      this.jsonErr.update((e) => ({ ...e, [key]: true }));
    }
  }
  asBool(v: unknown): boolean { return v === true || v === 'true' || v === 'yes' || v === 1; }
  num(v: unknown): number | null { const n = Number(v); return isNaN(n) ? null : n; }
  joinList(v: unknown): string { return Array.isArray(v) ? v.join('\n') : (v ?? '') as string; }
  splitList(s: string): string[] { return s.split('\n').map((x) => x.trim()).filter(Boolean); }
  /** The element schema of a list-of-objects. Accepts both shapes: a direct
   * {field: spec} map AND the JSON-Schema style {type:'object', properties:{…}}
   * the template miner emits. */
  private itemSpec(spec: ParamSpec): Record<string, ParamSpec> {
    const items = (spec.items ?? {}) as Record<string, unknown>;
    if (items['properties'] && typeof items['properties'] === 'object') {
      return items['properties'] as Record<string, ParamSpec>;
    }
    return items as Record<string, ParamSpec>;
  }
  itemCols(spec: ParamSpec): string[] { return Object.keys(this.itemSpec(spec)); }
  /** Table columns for a list-of-objects: the declared item schema when present,
   * otherwise the union of keys across the current rows (so a schema-less
   * pre-filled object list still renders an editable table). */
  colsFor(key: string, spec: ParamSpec): string[] {
    const declared = this.itemCols(spec);
    if (declared.length) return declared;
    const cols: string[] = [];
    for (const r of this.rows(key)) {
      for (const k of Object.keys(r || {})) if (!cols.includes(k)) cols.push(k);
    }
    return cols;
  }
  rows(key: string): Record<string, unknown>[] { const v = this.values()[key]; return Array.isArray(v) ? v as Record<string, unknown>[] : []; }

  set(key: string, value: unknown): void {
    this.overrides.update((o) => ({ ...o, [key]: value }));
    this.valuesChange.emit(this.values());
  }
  private setList(key: string, list: unknown[]): void { this.set(key, [...list]); }
  setRow(key: string, i: number, col: string, value: unknown): void {
    const list = [...this.rows(key)]; list[i] = { ...list[i], [col]: value }; this.setList(key, list);
  }
  addRow(key: string, spec: ParamSpec): void {
    const blank: Record<string, unknown> = {};
    const itemsSpec = this.itemSpec(spec);
    for (const c of this.colsFor(key, spec)) blank[c] = (itemsSpec[c] as ParamSpec | undefined)?.default ?? '';
    this.setList(key, [...this.rows(key), blank]);
  }
  delRow(key: string, i: number): void { const list = [...this.rows(key)]; list.splice(i, 1); this.setList(key, list); }

  /** Read the current values (for the wizard to submit). */
  snapshot(): Record<string, unknown> { return this.values(); }
}
