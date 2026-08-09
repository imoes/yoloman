import { Component, computed, input, output } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';

/** One filter's kind — mirrors the handful of Checkmk `Filter` subclasses we
 * actually need (option select, free text/regex, multi-chip, boolean). */
export type FilterKind = 'select' | 'text' | 'chips' | 'checkbox';

export interface FilterOption {
  value: string;
  label: string;
}

/** A reusable filter definition — the lightweight analogue of a Checkmk
 * registered `Filter` (ident + info + htmlvars). `ident` is the query key. */
export interface FilterDef {
  ident: string;
  label: string;
  kind: FilterKind;
  options?: FilterOption[];
  placeholder?: string;
}

/** The filter context: ident → value (Checkmk's VisualContext, flattened to
 * one value per filter since our filters are single-var). */
export type FilterValues = Record<string, string | boolean | null | undefined>;

/** Serialize a filter context into query params for a fleet endpoint — the
 * analogue of Checkmk's Filter.value()→FilterHeader step. Empty/false values
 * are dropped so the query stays clean. Shared by every service that filters. */
export function filterParams(values: FilterValues): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(values ?? {})) {
    if (v === null || v === undefined || v === '' || v === false) continue;
    out[k] = String(v);
  }
  return out;
}

/**
 * A single reusable filter bar rendered from a `FilterDef[]`, emitting the
 * merged `FilterValues` on any change (debounced for text). One consistent
 * filter UI across Problems, Security and the dashboard context — replacing
 * the per-page hand-rolled `<select>`/`<input>` sets, the way Checkmk renders
 * every view/dashboard filter from one registry-driven form.
 */
@Component({
  selector: 'app-filter-bar',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule],
  template: `
    <div class="bm-filter-bar">
      @for (f of filters(); track f.ident) {
        <div class="bm-filter" [class.bm-filter--wide]="f.kind === 'text'">
          @switch (f.kind) {
            @case ('select') {
              <label class="bm-filter-lbl">{{ f.label }}</label>
              <select [ngModel]="strVal(f.ident)" (ngModelChange)="set(f.ident, $event)">
                <option value="">All</option>
                @for (o of f.options ?? []; track o.value) { <option [value]="o.value">{{ o.label }}</option> }
              </select>
            }
            @case ('text') {
              <input type="text" [placeholder]="f.placeholder || f.label"
                     [ngModel]="strVal(f.ident)" (ngModelChange)="setDebounced(f.ident, $event)" />
            }
            @case ('checkbox') {
              <label class="bm-filter-chk">
                <input type="checkbox" [ngModel]="boolVal(f.ident)" (ngModelChange)="set(f.ident, $event)" />
                {{ f.label }}
              </label>
            }
            @case ('chips') {
              <label class="bm-filter-lbl">{{ f.label }}</label>
              <div class="bm-filter-chips">
                @for (o of f.options ?? []; track o.value) {
                  <button type="button" class="bm-chip" [class.bm-chip--on]="strVal(f.ident) === o.value"
                          (click)="set(f.ident, strVal(f.ident) === o.value ? '' : o.value)">{{ o.label }}</button>
                }
              </div>
            }
          }
        </div>
      }
      @if (hasActive()) {
        <button mat-button class="bm-filter-clear" (click)="clear()"><mat-icon>filter_alt_off</mat-icon> Clear</button>
      }
    </div>
  `,
  styles: [
    `
      .bm-filter-bar { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
      .bm-filter { display: flex; align-items: center; gap: 6px; }
      .bm-filter--wide { flex: 1; min-width: 180px; }
      .bm-filter-lbl { font-size: 12px; opacity: 0.7; }
      .bm-filter select, .bm-filter input[type='text'] {
        padding: 6px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px;
        background: var(--mat-sys-surface); color: inherit; font-size: 13px;
      }
      .bm-filter--wide input[type='text'] { width: 100%; }
      .bm-filter-chk { font-size: 12.5px; display: flex; align-items: center; gap: 5px; opacity: 0.85; }
      .bm-filter-chips { display: flex; gap: 6px; }
      .bm-chip {
        padding: 4px 10px; border-radius: 999px; border: 1px solid var(--mat-sys-outline-variant);
        background: var(--mat-sys-surface); color: inherit; font-size: 12px; cursor: pointer; text-transform: capitalize;
      }
      .bm-chip--on { background: color-mix(in srgb, var(--mat-sys-primary) 22%, transparent); border-color: var(--mat-sys-primary); font-weight: 600; }
      .bm-filter-clear { opacity: 0.8; }
    `,
  ],
})
export class FilterBarComponent {
  filters = input.required<FilterDef[]>();
  values = input<FilterValues>({});
  valuesChange = output<FilterValues>();

  private local = computed<FilterValues>(() => ({ ...this.values() }));
  private timer: ReturnType<typeof setTimeout> | null = null;

  strVal(ident: string): string {
    const v = this.local()[ident];
    return typeof v === 'string' ? v : '';
  }
  boolVal(ident: string): boolean {
    return this.local()[ident] === true;
  }
  hasActive(): boolean {
    return Object.keys(filterParams(this.local())).length > 0;
  }

  set(ident: string, value: string | boolean): void {
    this.valuesChange.emit({ ...this.local(), [ident]: value });
  }

  setDebounced(ident: string, value: string): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => this.set(ident, value), 300);
  }

  clear(): void {
    const cleared: FilterValues = {};
    for (const f of this.filters()) cleared[f.ident] = f.kind === 'checkbox' ? false : '';
    this.valuesChange.emit(cleared);
  }
}
