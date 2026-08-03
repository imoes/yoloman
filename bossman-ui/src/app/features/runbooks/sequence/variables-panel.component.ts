import { Component, computed, input, output, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { BUILTIN_VARIABLES } from '../blockly/ansibleFacts';

/** One row in the panel. `source` groups them; `preview` shows what the variable holds. */
export interface PanelVar {
  name: string;
  source: string;
  preview: string;
}

/**
 * The variables available to the open Sequence/Role — ported from awx-ng's VariablesPanel (React) which the
 * Blockly port left behind, which is why the Sequence editor showed no variables at all.
 *
 * A role is not usable without its variables, and SCCM makes the same point structurally: its task-sequence
 * search can scope to "Variable Name", i.e. variables are a first-class part of a sequence, not decoration.
 *
 * Four sources, in the order that matters to the operator:
 *   1. the document's own `parameters:` — the role's inputs, editable here
 *   2. `register:` names from steps in the document — available to LATER steps only
 *   3. `item` inside a step with `loop:`
 *   4. the built-in facts (blockly/ansibleFacts, kept in sync with internal/modules/setup.go)
 *
 * Click inserts `{{ name }}` into the focused field via the `insert` output; dragging carries the bare name
 * so the Blockly canvas keeps working (same `text/plain` contract as the awx-ng panel).
 */
@Component({
  selector: 'app-variables-panel',
  standalone: true,
  imports: [FormsModule, MatIconModule],
  template: `
    <div class="bm-vp">
      <div class="bm-vp-head">
        <input class="bm-vp-filter" type="text" [ngModel]="filter()" (ngModelChange)="filter.set($event)"
               placeholder="Filter variables…" />
        <button type="button" class="bm-vp-add" (click)="adding.set(!adding())"
                [title]="adding() ? 'Cancel' : 'Add a parameter to this document'">
          <mat-icon>{{ adding() ? 'close' : 'add' }}</mat-icon>
        </button>
      </div>

      @if (adding()) {
        <div class="bm-vp-new">
          <input type="text" [(ngModel)]="newName" placeholder="parameter name" />
          <input type="text" [(ngModel)]="newValue" placeholder="default (optional)" />
          <button type="button" [disabled]="!newName.trim()" (click)="emitCreate()">Add parameter</button>
        </div>
      }

      <div class="bm-vp-list">
        @for (group of grouped(); track group.source) {
          <div class="bm-vp-group">{{ group.source }}</div>
          @for (v of group.vars; track v.name) {
            <div class="bm-vp-item" draggable="true" (dragstart)="onDrag($event, v.name)"
                 (click)="insert.emit(v.name)"
                 [title]="'Click to insert {{ ' + v.name + ' }} — or drag it onto a field'">
              <code class="bm-vp-name">{{ v.name }}</code>
              @if (v.preview) { <span class="bm-vp-prev">{{ v.preview }}</span> }
            </div>
          }
        }
        @if (!grouped().length) {
          <p class="bm-vp-empty">Nothing matches “{{ filter() }}”.</p>
        }
      </div>
    </div>
  `,
  styles: [`
    .bm-vp { display: flex; flex-direction: column; height: 100%; min-height: 0; font-size: 12px; }
    .bm-vp-head { display: flex; gap: 6px; align-items: center; margin-bottom: 8px; }
    .bm-vp-filter { flex: 1; min-width: 0; padding: 5px 8px; font-size: 12px; color: inherit;
      background: var(--mat-sys-surface); border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; }
    .bm-vp-add { display: inline-flex; padding: 3px; border: 1px solid var(--mat-sys-outline-variant);
      border-radius: 6px; background: var(--mat-sys-surface); color: inherit; cursor: pointer; }
    .bm-vp-add mat-icon { font-size: 17px; width: 17px; height: 17px; }
    .bm-vp-new { display: flex; flex-direction: column; gap: 5px; margin-bottom: 8px; padding: 8px;
      border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; }
    .bm-vp-new input { padding: 5px 8px; font-size: 12px; color: inherit; background: var(--mat-sys-surface);
      border: 1px solid var(--mat-sys-outline-variant); border-radius: 5px; }
    .bm-vp-new button { padding: 5px 8px; font-size: 12px; cursor: pointer; border-radius: 5px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; }
    .bm-vp-new button:disabled { opacity: .45; cursor: default; }
    .bm-vp-list { flex: 1; min-height: 0; overflow-y: auto; }
    .bm-vp-group { font-size: 10.5px; text-transform: uppercase; letter-spacing: .04em; opacity: .5;
      margin: 10px 0 4px; }
    .bm-vp-group:first-child { margin-top: 0; }
    .bm-vp-item { padding: 3px 6px; border-radius: 5px; cursor: grab; display: flex; gap: 7px;
      align-items: baseline; }
    .bm-vp-item:hover { background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
    .bm-vp-name { font-family: ui-monospace, monospace; font-size: 11.5px; }
    .bm-vp-prev { font-size: 10.5px; opacity: .55; overflow: hidden; text-overflow: ellipsis;
      white-space: nowrap; }
    .bm-vp-empty { opacity: .5; font-size: 11.5px; }
  `],
})
export class VariablesPanelComponent {
  /** The document's `parameters:` — {name: spec-or-value}. */
  parameters = input<Record<string, unknown>>({});
  /** `register:` names collected from the document's steps. */
  registers = input<string[]>([]);
  /** True when the selected step has a `loop:`, which is the only place `item` is bound. */
  inLoop = input(false);

  /** A variable the operator picked — the editor inserts `{{ name }}` into the focused field. */
  insert = output<string>();
  /** A new document parameter: [name, default]. */
  create = output<{ name: string; value: string }>();

  filter = signal('');
  adding = signal(false);
  newName = '';
  newValue = '';

  private all = computed<PanelVar[]>(() => {
    const params = Object.entries(this.parameters() || {}).map(([name, spec]) => ({
      name,
      source: 'document parameter',
      preview: preview(spec),
    }));
    const regs = this.registers().map((name) => ({
      name,
      source: 'registered result',
      // Worth stating: a register is only bound for steps AFTER the one that set it.
      preview: 'result of an earlier step',
    }));
    // `item` exists only inside a loop, so offering it elsewhere would be offering something undefined.
    const builtins = BUILTIN_VARIABLES.filter((v) => v.name !== 'item' || this.inLoop());
    const seen = new Set<string>();
    return [...params, ...regs, ...builtins].filter((v) => {
      if (seen.has(v.name)) return false;      // the document's own value wins over a built-in of that name
      seen.add(v.name);
      return true;
    });
  });

  grouped = computed(() => {
    const q = this.filter().trim().toLowerCase();
    const hits = q ? this.all().filter((v) => v.name.toLowerCase().includes(q)) : this.all();
    const out: { source: string; vars: PanelVar[] }[] = [];
    for (const v of hits) {
      const last = out[out.length - 1];
      if (last && last.source === v.source) last.vars.push(v);
      else out.push({ source: v.source, vars: [v] });
    }
    return out;
  });

  onDrag(ev: DragEvent, name: string): void {
    // Bare name, matching the awx-ng contract, so dropping onto the Blockly canvas still yields a var block.
    ev.dataTransfer?.setData('text/plain', name);
    if (ev.dataTransfer) ev.dataTransfer.effectAllowed = 'copy';
  }

  emitCreate(): void {
    const name = this.newName.trim();
    if (!name) return;
    this.create.emit({ name, value: this.newValue });
    this.newName = '';
    this.newValue = '';
    this.adding.set(false);
  }
}

/** Single-line preview of a parameter's default, whether it is a typed spec or a bare value. */
function preview(spec: unknown): string {
  const value = spec && typeof spec === 'object' && 'default' in (spec as object)
    ? (spec as { default: unknown }).default
    : spec;
  if (value === null || value === undefined || value === '') return '';
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  return text.length > 32 ? `${text.slice(0, 32)}…` : text;
}
