import { Component, OnInit, computed, input, output, signal } from '@angular/core';
import { NgTemplateOutlet } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { ParamSchema, ParamSpec } from './param-form.types';

interface Field { key: string; spec: ParamSpec; }

/** Generic input mask rendered from a typed parameter schema (nt_runbook
 * parameters). Each field shows its description and its default value; required/
 * default-less fields are essential, the rest hide behind an "Advanced" toggle.
 * Handles string/number/bool/enum/secret, string-lists and list-of-objects
 * (inline table editor). The wizard and any runbook-run dialog reuse it. */
@Component({
  selector: 'app-param-form',
  standalone: true,
  imports: [NgTemplateOutlet, FormsModule, MatFormFieldModule, MatInputModule, MatSelectModule, MatSlideToggleModule, MatButtonModule, MatIconModule],
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
        <label class="bm-pf-label">{{ label(f.key) }}@if (f.spec.required) { <span class="bm-pf-req">*</span> }</label>

        @switch (control(f.spec)) {
          @case ('bool') {
            <mat-slide-toggle [ngModel]="asBool(values()[f.key])" (ngModelChange)="set(f.key, $event)">{{ asBool(values()[f.key]) ? 'yes' : 'no' }}</mat-slide-toggle>
          }
          @case ('enum') {
            <mat-form-field appearance="outline" subscriptSizing="dynamic" class="bm-pf-ctl">
              <mat-select [ngModel]="values()[f.key]" (ngModelChange)="set(f.key, $event)">
                @for (o of f.spec.enum; track o) { <mat-option [value]="o">{{ o }}</mat-option> }
              </mat-select>
            </mat-form-field>
          }
          @case ('number') {
            <mat-form-field appearance="outline" subscriptSizing="dynamic" class="bm-pf-ctl">
              <input matInput type="number" [ngModel]="values()[f.key]" (ngModelChange)="set(f.key, num($event))" />
            </mat-form-field>
          }
          @case ('secret') {
            <mat-form-field appearance="outline" subscriptSizing="dynamic" class="bm-pf-ctl">
              <input matInput type="password" [ngModel]="values()[f.key]" (ngModelChange)="set(f.key, $event)" />
            </mat-form-field>
          }
          @case ('stringlist') {
            <mat-form-field appearance="outline" subscriptSizing="dynamic" class="bm-pf-ctl">
              <textarea matInput rows="2" [ngModel]="joinList(values()[f.key])" (ngModelChange)="set(f.key, splitList($event))" placeholder="one per line"></textarea>
            </mat-form-field>
          }
          @case ('objlist') {
            <div class="bm-pf-tbl">
              <table>
                <thead><tr>@for (c of itemCols(f.spec); track c) { <th>{{ c }}</th> }<th></th></tr></thead>
                <tbody>
                  @for (row of rows(f.key); track $index) {
                    <tr>
                      @for (c of itemCols(f.spec); track c) {
                        <td><input class="bm-pf-cell" [ngModel]="row[c]" (ngModelChange)="setRow(f.key, $index, c, $event)" /></td>
                      }
                      <td><button type="button" class="bm-pf-x" (click)="delRow(f.key, $index)"><mat-icon>close</mat-icon></button></td>
                    </tr>
                  }
                </tbody>
              </table>
              <button type="button" mat-stroked-button class="bm-pf-addrow" (click)="addRow(f.key, f.spec)"><mat-icon>add</mat-icon> Add row</button>
            </div>
          }
          @default {
            <mat-form-field appearance="outline" subscriptSizing="dynamic" class="bm-pf-ctl">
              <input matInput [ngModel]="values()[f.key]" (ngModelChange)="set(f.key, $event)" />
            </mat-form-field>
          }
        }
        @if (f.spec.description) { <div class="bm-pf-desc">{{ f.spec.description }}</div> }
        @if (defaultHint(f.spec)) { <div class="bm-pf-default">Default: <code>{{ defaultHint(f.spec) }}</code></div> }
      </div>
    </ng-template>
  `,
  styles: [`
    :host { display: block; max-width: 640px; }
    .bm-pf-field { margin-bottom: 14px; }
    .bm-pf-label { display: block; font-size: 13px; font-weight: 600; margin-bottom: 4px; }
    .bm-pf-req { color: var(--bm-red, #c62828); margin-left: 3px; }
    .bm-pf-ctl { width: 100%; }
    .bm-pf-desc { font-size: 12px; opacity: 0.62; line-height: 1.4; margin-top: 3px; }
    .bm-pf-default { font-size: 11.5px; opacity: 0.5; margin-top: 2px; }
    .bm-pf-default code { font-family: ui-monospace, monospace; }
    .bm-pf-adv { background: none; border: none; color: var(--mat-sys-primary); cursor: pointer; display: flex; align-items: center; gap: 4px; font-size: 13px; margin: 6px 0 12px; }
    .bm-pf-tbl table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
    .bm-pf-tbl th { text-align: left; opacity: 0.6; padding: 3px 6px; font-weight: 500; }
    .bm-pf-tbl td { padding: 2px 4px; border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-pf-cell { width: 100%; background: transparent; border: 1px solid var(--mat-sys-outline-variant); border-radius: 4px; color: inherit; padding: 4px 6px; box-sizing: border-box; }
    .bm-pf-x { background: none; border: none; color: var(--bm-red, #c62828); cursor: pointer; }
    .bm-pf-addrow { margin-top: 6px; }
  `],
})
export class ParamFormComponent implements OnInit {
  params = input.required<ParamSchema>();
  initial = input<Record<string, unknown>>({});
  valuesChange = output<Record<string, unknown>>();

  /** Emit the prefilled defaults immediately so a consumer that never edits a
   * field still receives the full value set (the wizard runs on defaults). */
  ngOnInit(): void { this.valuesChange.emit(this.values()); }

  showAdvanced = signal(false);
  private overrides = signal<Record<string, unknown>>({});

  /** Visible (non-hidden) fields, defaults prefilled from initial ∪ spec.default. */
  private fields = computed<Field[]>(() =>
    Object.entries(this.params())
      .filter(([, s]) => !s.hidden)
      .map(([key, spec]) => ({ key, spec })));

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

  control(spec: ParamSpec): string {
    if (spec.secret) return 'secret';
    if (spec.enum?.length) return 'enum';
    if (spec.type === 'bool') return 'bool';
    if (spec.type === 'number') return 'number';
    if (spec.type === 'list') return spec.items ? 'objlist' : 'stringlist';
    return 'text';
  }

  private blank(spec: ParamSpec): unknown {
    if (spec.type === 'bool') return false;
    if (spec.type === 'list') return [];
    if (spec.type === 'number') return null;
    return '';
  }

  label(key: string): string {
    return key.replace(/_/g, ' ').replace(/\b\w/g, (m) => m.toUpperCase());
  }
  defaultHint(spec: ParamSpec): string {
    if (spec.default === undefined || spec.default === null || spec.default === '') return '';
    return Array.isArray(spec.default) ? spec.default.join(', ') : String(spec.default);
  }
  asBool(v: unknown): boolean { return v === true || v === 'true' || v === 'yes' || v === 1; }
  num(v: unknown): number | null { const n = Number(v); return isNaN(n) ? null : n; }
  joinList(v: unknown): string { return Array.isArray(v) ? v.join('\n') : (v ?? '') as string; }
  splitList(s: string): string[] { return s.split('\n').map((x) => x.trim()).filter(Boolean); }
  itemCols(spec: ParamSpec): string[] { return Object.keys(spec.items ?? {}); }
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
    for (const [c, s] of Object.entries(spec.items ?? {})) blank[c] = s.default ?? '';
    this.setList(key, [...this.rows(key), blank]);
  }
  delRow(key: string, i: number): void { const list = [...this.rows(key)]; list.splice(i, 1); this.setList(key, list); }

  /** Read the current values (for the wizard to submit). */
  snapshot(): Record<string, unknown> { return this.values(); }
}
