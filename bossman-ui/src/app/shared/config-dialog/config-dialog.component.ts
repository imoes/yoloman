import { Component, Inject, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatRadioModule } from '@angular/material/radio';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { MatTooltipModule } from '@angular/material/tooltip';
import { isObservable, lastValueFrom } from 'rxjs';
import { ConfigDialogDef, ConfigField, FieldValues } from './config-dialog.types';
import { SizeSliderComponent } from './size-slider.component';
import { fmtBytes } from './usage-bar.component';

/** Generic renderer for a ConfigDialogDef — mirrors Cockpit's dialog.jsx
 * make_rows/Field. Keeps a live values map, applies per-field visibility +
 * validation, runs def.update on change, and executes the action with a
 * spinner and inline error surface (global string vs per-field {tag:msg}). */
@Component({
  selector: 'app-config-dialog',
  standalone: true,
  imports: [
    FormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatSelectModule,
    MatButtonModule, MatIconModule, MatCheckboxModule, MatRadioModule,
    MatProgressSpinnerModule, MatTooltipModule, SizeSliderComponent,
  ],
  template: `
    <h2 mat-dialog-title>{{ def.title }}</h2>
    <mat-dialog-content>
      @if (def.body) { <p class="cd-body">{{ def.body }}</p> }
      @if (globalError()) { <p class="cd-err">{{ globalError() }}</p> }

      @for (f of visibleFields(); track f.tag) {
        <div class="cd-row">
          @switch (f.type) {
            @case ('message') { <p class="cd-msg">{{ f.text }}</p> }

            @case ('text') {
              <mat-form-field appearance="outline" class="cd-full">
                <mat-label>{{ f.title }}</mat-label>
                <input matInput [ngModel]="strVal(f.tag)" (ngModelChange)="set(f.tag, $event)" [placeholder]="f.placeholder || ''" />
                @if (fieldError(f.tag)) { <mat-error>{{ fieldError(f.tag) }}</mat-error> }
                @if (f.help) { <mat-hint>{{ f.help }}</mat-hint> }
              </mat-form-field>
            }

            @case ('password') {
              <mat-form-field appearance="outline" class="cd-full">
                <mat-label>{{ f.title }}</mat-label>
                <input matInput type="password" [ngModel]="strVal(f.tag)" (ngModelChange)="set(f.tag, $event)" />
                @if (fieldError(f.tag)) { <mat-error>{{ fieldError(f.tag) }}</mat-error> }
              </mat-form-field>
            }

            @case ('select') {
              <mat-form-field appearance="outline" class="cd-full">
                <mat-label>{{ f.title }}</mat-label>
                <mat-select [ngModel]="val(f.tag)" (ngModelChange)="set(f.tag, $event)">
                  @for (c of f.choices || []; track c.value) {
                    <mat-option [value]="c.value" [disabled]="c.disabled">{{ c.title }}</mat-option>
                  }
                </mat-select>
              </mat-form-field>
            }

            @case ('radio') {
              <label class="cd-label">{{ f.title }}</label>
              <mat-radio-group [ngModel]="val(f.tag)" (ngModelChange)="set(f.tag, $event)" class="cd-radios">
                @for (c of f.choices || []; track c.value) {
                  <mat-radio-button [value]="c.value" [disabled]="c.disabled">
                    {{ c.title }}
                    @if (c.explanation) { <span class="cd-expl">{{ c.explanation }}</span> }
                  </mat-radio-button>
                }
              </mat-radio-group>
            }

            @case ('checkboxes') {
              <label class="cd-label">{{ f.title }}</label>
              <div class="cd-checks">
                @for (it of f.items || []; track it.tag) {
                  <mat-checkbox [ngModel]="hasCheck(f.tag, it.tag)" (ngModelChange)="toggleCheck(f.tag, it.tag, $event)" [matTooltip]="it.tooltip || ''">{{ it.title }}</mat-checkbox>
                }
              </div>
            }

            @case ('checkboxWithInput') {
              <div class="cd-cwi">
                <mat-checkbox [ngModel]="cwiOn(f.tag)" (ngModelChange)="setCwi(f.tag, $event, cwiText(f.tag))">{{ f.checkboxLabel || f.title }}</mat-checkbox>
                @if (cwiOn(f.tag)) {
                  <mat-form-field appearance="outline" class="cd-full">
                    <input matInput [ngModel]="cwiText(f.tag)" (ngModelChange)="setCwi(f.tag, true, $event)" [placeholder]="f.inputPlaceholder || ''" />
                  </mat-form-field>
                }
              </div>
            }

            @case ('stringList') {
              <label class="cd-label">{{ f.title }}</label>
              <div class="cd-list">
                @for (item of listVal(f.tag); track $index) {
                  <div class="cd-list-row">
                    <mat-form-field appearance="outline" class="cd-full">
                      <input matInput [ngModel]="item" (ngModelChange)="setListItem(f.tag, $index, $event)" [placeholder]="f.placeholder || ''" />
                    </mat-form-field>
                    <button mat-icon-button (click)="removeListItem(f.tag, $index)"><mat-icon>remove</mat-icon></button>
                  </div>
                }
                <button mat-stroked-button (click)="addListItem(f.tag)"><mat-icon>add</mat-icon> Add</button>
              </div>
            }

            @case ('sizeSlider') {
              <label class="cd-label">{{ f.title }}</label>
              <app-size-slider [value]="numVal(f.tag)" (valueChange)="set(f.tag, $event)"
                [min]="f.min || 0" [max]="f.max || 0" [round]="f.round || 1048576" [allowInfinite]="!!f.allowInfinite" />
            }

            @case ('selectSpaces') {
              <label class="cd-label">{{ f.title }}</label>
              <div class="cd-spaces">
                @for (sp of f.spaces || []; track sp.value) {
                  <mat-checkbox [ngModel]="hasSpace(f.tag, sp.value)" (ngModelChange)="toggleSpace(f.tag, sp.value, $event)" [disabled]="!!sp.disabled">
                    {{ sp.title }} @if (sp.size) { <span class="cd-sz">{{ bytes(sp.size) }}</span> }
                  </mat-checkbox>
                }
                @if (fieldError(f.tag)) { <p class="cd-err">{{ fieldError(f.tag) }}</p> }
              </div>
            }
          }
        </div>
      }

      @if (def.danger) { <p class="cd-danger"><mat-icon>warning</mat-icon> {{ def.danger }}</p> }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      @if (busy()) { <mat-spinner diameter="20" class="cd-spin" /> }
      <button mat-button (click)="dialogRef.close()" [disabled]="busy()">Cancel</button>
      @if (def.variants?.length) {
        @for (v of def.variants; track v.variant) {
          @if (v.primary) {
            <button mat-raised-button [color]="def.dangerButton ? 'warn' : 'primary'" [disabled]="busy() || hasErrors()" (click)="submit(v.variant)">{{ v.title }}</button>
          } @else {
            <button mat-stroked-button [disabled]="busy() || hasErrors()" (click)="submit(v.variant)">{{ v.title }}</button>
          }
        }
      } @else {
        <button mat-raised-button [color]="def.dangerButton ? 'warn' : 'primary'" [disabled]="busy() || hasErrors()" (click)="submit()">{{ def.submitLabel || 'Apply' }}</button>
      }
    </mat-dialog-actions>
  `,
  styles: [
    `
      mat-dialog-content { min-width: 460px; max-width: 640px; }
      .cd-body { font-size: 13px; opacity: 0.85; margin: 0 0 12px; }
      .cd-row { margin-bottom: 12px; }
      .cd-full { width: 100%; }
      .cd-label { display: block; font-size: 12.5px; opacity: 0.75; margin-bottom: 6px; }
      .cd-radios { display: flex; flex-direction: column; gap: 6px; }
      .cd-expl { display: block; font-size: 11.5px; opacity: 0.6; margin-left: 2px; }
      .cd-checks, .cd-spaces { display: flex; flex-direction: column; gap: 4px; }
      .cd-sz { opacity: 0.6; font-family: monospace; font-size: 11.5px; margin-left: 6px; }
      .cd-list { display: flex; flex-direction: column; gap: 4px; }
      .cd-list-row { display: flex; align-items: center; gap: 6px; }
      .cd-msg { font-size: 12.5px; opacity: 0.75; margin: 0; }
      .cd-cwi { display: flex; flex-direction: column; gap: 6px; }
      .cd-err { color: #c62828; font-size: 12.5px; margin: 4px 0; }
      .cd-danger { display: flex; align-items: center; gap: 6px; color: #e65100; font-size: 12.5px; }
      .cd-danger mat-icon { font-size: 18px; width: 18px; height: 18px; }
      .cd-spin { margin-right: 8px; }
    `,
  ],
})
export class ConfigDialogComponent {
  dialogRef = inject(MatDialogRef<ConfigDialogComponent, unknown>);
  def: ConfigDialogDef;

  private values = signal<FieldValues>({});
  private overrides = signal<Record<string, Partial<ConfigField>>>({});
  busy = signal(false);
  globalError = signal<string | null>(null);
  private fieldErrors = signal<Record<string, string>>({});

  constructor(@Inject(MAT_DIALOG_DATA) data: ConfigDialogDef) {
    this.def = data;
    const init: FieldValues = {};
    for (const f of data.fields) init[f.tag] = f.initial ?? defaultFor(f);
    this.values.set(init);
  }

  /** Field descriptor merged with any live override from def.update. */
  private merged(f: ConfigField): ConfigField {
    const ov = this.overrides()[f.tag];
    return ov ? { ...f, ...ov } : f;
  }

  visibleFields = computed(() => {
    const v = this.values();
    return this.def.fields.map((f) => this.merged(f)).filter((f) => (f.visible ? f.visible(v) : true));
  });

  val(tag: string): unknown { return this.values()[tag]; }
  strVal(tag: string): string { return (this.values()[tag] as string) ?? ''; }
  numVal(tag: string): number { return (this.values()[tag] as number) ?? 0; }
  listVal(tag: string): string[] { return (this.values()[tag] as string[]) ?? []; }

  set(tag: string, value: unknown): void {
    this.values.update((v) => ({ ...v, [tag]: value }));
    this.runUpdate(tag);
    this.validateAll();
  }

  // stringList
  addListItem(tag: string): void { this.set(tag, [...this.listVal(tag), '']); }
  removeListItem(tag: string, i: number): void { const l = [...this.listVal(tag)]; l.splice(i, 1); this.set(tag, l); }
  setListItem(tag: string, i: number, value: string): void { const l = [...this.listVal(tag)]; l[i] = value; this.set(tag, l); }

  // checkboxes (value = string[] of checked tags)
  hasCheck(tag: string, item: string): boolean { return (this.listVal(tag)).includes(item); }
  toggleCheck(tag: string, item: string, on: boolean): void {
    const s = new Set(this.listVal(tag));
    on ? s.add(item) : s.delete(item);
    this.set(tag, [...s]);
  }

  // selectSpaces (value = string[])
  hasSpace(tag: string, sp: string): boolean { return this.listVal(tag).includes(sp); }
  toggleSpace(tag: string, sp: string, on: boolean): void { this.toggleCheck(tag, sp, on); }

  // checkboxWithInput (value = {enabled, text})
  private cwi(tag: string): { enabled: boolean; text: string } {
    return (this.values()[tag] as { enabled: boolean; text: string }) ?? { enabled: false, text: '' };
  }
  cwiOn(tag: string): boolean { return this.cwi(tag).enabled; }
  cwiText(tag: string): string { return this.cwi(tag).text; }
  setCwi(tag: string, enabled: boolean, text: string): void { this.set(tag, { enabled, text }); }

  bytes(n: number): string { return fmtBytes(n); }

  private runUpdate(trigger: string): void {
    if (!this.def.update) return;
    const patch = this.def.update(this.values(), trigger);
    if (patch) this.overrides.update((o) => ({ ...o, ...patch }));
  }

  private validateAll(): void {
    const errs: Record<string, string> = {};
    const v = this.values();
    for (const f of this.visibleFields()) {
      if (f.type === 'selectSpaces' && f.minSelected && this.listVal(f.tag).length < f.minSelected) {
        errs[f.tag] = f.emptyWarning || `Select at least ${f.minSelected}`;
      }
      if (f.validate) {
        const e = f.validate(v[f.tag], v);
        if (e) errs[f.tag] = e;
      }
    }
    this.fieldErrors.set(errs);
  }

  fieldError(tag: string): string | null { return this.fieldErrors()[tag] ?? null; }
  hasErrors(): boolean { return Object.keys(this.fieldErrors()).length > 0; }

  async submit(variant?: string): Promise<void> {
    this.validateAll();
    if (this.hasErrors()) return;
    this.busy.set(true);
    this.globalError.set(null);
    try {
      const r = this.def.action(this.values(), variant);
      const result = isObservable(r) ? await lastValueFrom(r) : await r;
      this.dialogRef.close(result ?? true);
    } catch (e: unknown) {
      this.applyError(e);
    } finally {
      this.busy.set(false);
    }
  }

  private applyError(e: unknown): void {
    if (typeof e === 'string') { this.globalError.set(e); return; }
    if (e && typeof e === 'object') {
      const anyE = e as Record<string, unknown>;
      const detail = (anyE['error'] as { detail?: string })?.detail ?? anyE['message'];
      if (typeof detail === 'string') { this.globalError.set(detail); return; }
      // {tag: message} field errors
      const errs: Record<string, string> = {};
      for (const [k, v] of Object.entries(anyE)) if (typeof v === 'string') errs[k] = v;
      if (Object.keys(errs).length) { this.fieldErrors.set(errs); return; }
    }
    this.globalError.set('action failed');
  }
}

function defaultFor(f: ConfigField): unknown {
  switch (f.type) {
    case 'checkboxes':
    case 'selectSpaces':
    case 'stringList': return [];
    case 'checkboxWithInput': return { enabled: false, text: '' };
    case 'sizeSlider': return f.min ?? 0;
    case 'select':
    case 'radio': return f.choices?.[0]?.value ?? '';
    default: return '';
  }
}
