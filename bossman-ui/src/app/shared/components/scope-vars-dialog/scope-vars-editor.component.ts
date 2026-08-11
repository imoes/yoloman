import { Component, EventEmitter, Input, OnInit, Output, effect, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../../environments/environment';

/** One scalar leaf of a variable — the actual value plus its scalar type. In a
 * list every leaf's `name` is empty; in a dict every kept leaf carries a name. */
type Kind = 'text' | 'number' | 'bool';
interface Leaf { name: string; value: string; kind: Kind; }
/** One variable: a name plus one-or-more leaves. Shape is INFERRED from the form
 * — 1 unnamed leaf = scalar, ≥2 unnamed = list, any named leaf = dict — so there
 * is no type dropdown for the container; you grow it with "+" and name entries. */
interface VarRow { key: string; leaves: Leaf[]; secret: boolean; }
const MASK = '••••••••';

/**
 * The variable editor as a reusable form (embedded in the host Configuration tab
 * and wrapped by ScopeVarsDialog for OU/group scopes). Playbook vars are not only
 * scalars — they are frequently LISTS and DICTS. Instead of asking the user to
 * write JSON, the shape is built by direct manipulation:
 *
 *   • a variable starts as a single value (with a compact text/number/bool type);
 *   • press "+" under the value to add another entry → it becomes a LIST;
 *   • give the entries names → it becomes a DICT.
 *
 * The real structure is stored (scope-vars is JSONB), so `{{ packages }}` reaches
 * the playbook as an actual list and `{{ nginx.worker_processes }}` as a real
 * dict. Secrets stay scalar text (encrypted at rest).
 */
@Component({
  selector: 'app-scope-vars-editor',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatIconModule],
  template: `
    @if (scopeLabel) {
      <p class="sv-dim">Set directly on this scope. Resolved GPO-style at run time
        (group &lt; OU root→leaf &lt; host); deeper/host values win. Start with a value,
        press <mat-icon class="sv-inl">add</mat-icon> to make it a <strong>list</strong>,
        and name the entries to make it a <strong>dict</strong>.</p>
    }
    @for (r of rows(); track $index) {
      <div class="sv-row">
        <!-- The variable NAME and its VALUE sit on one line. A scalar keeps its
             single value here; a list/dict shows a shape chip and its entries
             (each name-beside-value) drop below. -->
        <div class="sv-row-head">
          <input class="sv-in sv-key" [ngModel]="r.key" (ngModelChange)="setKey($index, $event)" placeholder="variable name" />
          @if (!structured(r)) {
            @if (r.leaves[0].kind === 'bool') {
              <select class="sv-in sv-val" [ngModel]="r.leaves[0].value" (ngModelChange)="setLeafValue($index, 0, $event)">
                <option value="true">true</option><option value="false">false</option>
              </select>
            } @else {
              <input class="sv-in sv-val" [type]="r.secret ? 'password' : 'text'"
                     [ngModel]="r.leaves[0].value" (ngModelChange)="setLeafValue($index, 0, $event)"
                     (focus)="onSecretFocus($index, 0)"
                     [placeholder]="r.secret ? '••••••••' : (r.leaves[0].kind === 'number' ? '3306' : 'value')" />
            }
            @if (!r.secret) {
              <select class="sv-in sv-type" [ngModel]="r.leaves[0].kind" (ngModelChange)="setLeafKind($index, 0, $event)" title="Value type">
                <option value="text">abc</option><option value="number">123</option><option value="bool">☑</option>
              </select>
            }
            @if (isScalarText(r)) {
              <button type="button" class="sv-iconbtn" (click)="toggleSecret($index)"
                      [class.on]="r.secret" [title]="r.secret ? 'Secret — encrypted at rest' : 'Mark as secret (encrypt at rest)'">
                <mat-icon>{{ r.secret ? 'lock' : 'lock_open' }}</mat-icon>
              </button>
            }
          } @else {
            <span class="sv-shape" [attr.data-shape]="shape(r)">{{ shape(r) }}</span>
          }
          <button type="button" class="sv-iconbtn" (click)="removeRow($index)" title="Remove variable"><mat-icon>close</mat-icon></button>
        </div>

        <!-- List/dict entries: each row is name-beside-value. -->
        @if (structured(r)) {
          <div class="sv-leaves">
            @for (l of r.leaves; track $index; let li = $index) {
              <div class="sv-leaf">
                <input class="sv-in sv-name" [ngModel]="l.name" (ngModelChange)="setLeafName($index, li, $event)"
                       placeholder="leave empty for list · name it for a dict"
                       title="Leave the name empty and this entry is a list item; type a name and the variable becomes a dict." />
                @if (l.kind === 'bool') {
                  <select class="sv-in sv-val" [ngModel]="l.value" (ngModelChange)="setLeafValue($index, li, $event)">
                    <option value="true">true</option><option value="false">false</option>
                  </select>
                } @else {
                  <input class="sv-in sv-val" [ngModel]="l.value" (ngModelChange)="setLeafValue($index, li, $event)"
                         [placeholder]="l.kind === 'number' ? '3306' : 'value'" />
                }
                <select class="sv-in sv-type" [ngModel]="l.kind" (ngModelChange)="setLeafKind($index, li, $event)" title="Value type">
                  <option value="text">abc</option><option value="number">123</option><option value="bool">☑</option>
                </select>
                @if (r.leaves.length > 1) {
                  <button type="button" class="sv-iconbtn" (click)="removeLeaf($index, li)" title="Remove entry"><mat-icon>remove</mat-icon></button>
                }
              </div>
            }
          </div>
        }

        <button type="button" class="sv-addleaf" (click)="addLeaf($index)">
          <mat-icon>add</mat-icon> {{ structured(r) ? 'Add entry' : 'Make a list / dict' }}
        </button>
      </div>
    }
    <button type="button" class="sv-addrow" (click)="addRow()"><mat-icon>add</mat-icon> Add variable</button>
    @if (error()) { <p class="sv-err">{{ error() }}</p> }

    @if (embedded) {
      <div class="sv-actions">
        <button type="button" class="sv-save" (click)="save()" [disabled]="busy()">{{ busy() ? 'Saving…' : 'Save variables' }}</button>
        @if (savedMsg()) { <span class="sv-ok">{{ savedMsg() }}</span> }
      </div>
    }
  `,
  styles: [`
    :host { display: block; }
    .sv-dim { opacity: 0.72; font-size: 13px; margin: 0 0 12px; max-width: 640px; line-height: 1.5; }
    .sv-inl { font-size: 15px; height: 15px; width: 15px; vertical-align: -3px; opacity: 0.8; }
    .sv-err { color: var(--mat-sys-error, #c62828); font-size: 13px; }
    .sv-ok { color: #66bb6a; font-size: 13px; margin-left: 10px; }
    .sv-row { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 10px; margin-bottom: 10px; }
    .sv-row-head { display: flex; align-items: center; gap: 8px; }
    .sv-shape { font-size: 10.5px; text-transform: uppercase; letter-spacing: .5px; opacity: 0.6; padding: 2px 7px; border-radius: 20px; border: 1px solid var(--mat-sys-outline-variant); }
    .sv-shape[data-shape="list"] { color: #42a5f5; border-color: color-mix(in srgb, #42a5f5 40%, transparent); }
    .sv-shape[data-shape="dict"] { color: #ab47bc; border-color: color-mix(in srgb, #ab47bc 40%, transparent); }
    .sv-leaves { margin: 8px 0 0 4px; padding-left: 8px; border-left: 2px solid var(--mat-sys-outline-variant); }
    .sv-leaf { display: flex; align-items: center; gap: 6px; margin-bottom: 6px; }
    .sv-in { padding: 6px 8px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; box-sizing: border-box; font: inherit; }
    .sv-key { flex: 1; font-weight: 600; }
    .sv-name { width: 210px; }
    .sv-name::placeholder { font-size: 11px; opacity: 0.6; }
    .sv-val { flex: 1; min-width: 120px; }
    .sv-type { width: 58px; text-align: center; }
    .sv-iconbtn { display: inline-flex; align-items: center; justify-content: center; width: 30px; height: 30px; border: 0; border-radius: 6px; background: none; color: inherit; cursor: pointer; opacity: 0.7; }
    .sv-iconbtn:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); opacity: 1; }
    .sv-iconbtn.on { color: var(--mat-sys-primary); opacity: 1; }
    .sv-iconbtn mat-icon { font-size: 18px; height: 18px; width: 18px; }
    .sv-addleaf, .sv-addrow { display: inline-flex; align-items: center; gap: 5px; border: 0; background: none; color: var(--mat-sys-primary); cursor: pointer; font: inherit; font-size: 13px; padding: 4px 6px; border-radius: 6px; }
    .sv-addleaf:hover, .sv-addrow:hover { background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
    .sv-addleaf mat-icon, .sv-addrow mat-icon { font-size: 17px; height: 17px; width: 17px; }
    .sv-addrow { margin-top: 4px; }
    .sv-actions { margin-top: 14px; display: flex; align-items: center; }
    .sv-save { background: var(--mat-sys-primary); color: var(--mat-sys-on-primary); border: 0; border-radius: 8px; padding: 8px 18px; font: inherit; font-weight: 600; cursor: pointer; }
    .sv-save:disabled { opacity: 0.6; cursor: default; }
  `],
})
export class ScopeVarsEditorComponent implements OnInit {
  @Input({ required: true }) scopeType!: 'ou' | 'group' | 'host';
  @Input({ required: true }) scopeId!: string;
  @Input() scopeLabel = '';
  /** Embedded (Configuration tab) shows its own Save button; in the dialog the
   * dialog's action bar drives save() instead. */
  @Input() embedded = false;
  /** Bump to force a reload (e.g. after out-of-band provisioning wrote host_vars). */
  reloadTick = input(0);
  @Output() saved = new EventEmitter<void>();

  private http = inject(HttpClient);
  private base = environment.apiUrl;
  rows = signal<VarRow[]>([]);
  error = signal('');
  savedMsg = signal('');
  busy = signal(false);

  constructor() {
    // Reload when the parent bumps reloadTick (post-provisioning), not on the
    // initial 0 (ngOnInit already does the first load).
    effect(() => { if (this.reloadTick() > 0) this.ngOnInit(); });
  }

  // ── shape helpers ─────────────────────────────────────────────────────────
  structured(r: VarRow): boolean { return r.leaves.length > 1 || r.leaves.some((l) => l.name.trim() !== ''); }
  shape(r: VarRow): 'value' | 'list' | 'dict' {
    if (!this.structured(r)) return 'value';
    return r.leaves.some((l) => l.name.trim() !== '') ? 'dict' : 'list';
  }
  isScalarText(r: VarRow): boolean { return !this.structured(r) && r.leaves[0]?.kind === 'text'; }

  // ── load ───────────────────────────────────────────────────────────────────
  private idParam(): string {
    const key = { ou: 'ou_id', group: 'host_group_id', host: 'agent_id' }[this.scopeType];
    return `${key}=${this.scopeId}`;
  }
  private kindOf(v: unknown): Kind {
    if (typeof v === 'boolean') return 'bool';
    if (typeof v === 'number') return 'number';
    return 'text';
  }
  private leaf(name: string, value: unknown, kind: Kind): Leaf { return { name, value: String(value), kind }; }
  /** Turn a stored value into the form's leaves. */
  private toLeaves(value: unknown, secret: boolean): Leaf[] {
    if (secret) return [this.leaf('', MASK, 'text')];
    if (Array.isArray(value)) return value.length ? value.map((v) => this.leaf('', v, this.kindOf(v))) : [this.leaf('', '', 'text')];
    if (value !== null && typeof value === 'object') {
      const es = Object.entries(value as Record<string, unknown>);
      return es.length ? es.map(([k, v]) => this.leaf(k, v, this.kindOf(v))) : [this.leaf('', '', 'text')];
    }
    return [this.leaf('', value ?? '', this.kindOf(value))];
  }

  ngOnInit(): void {
    this.http.get<{ vars: Record<string, unknown>; secret_keys?: string[] }>(
      `${this.base}/scope-vars?scope_type=${this.scopeType}&${this.idParam()}`,
    ).subscribe((r) => {
      const secret = new Set(r.secret_keys || []);
      const rows = Object.entries(r.vars || {}).map(([key, value]): VarRow => ({
        key, secret: secret.has(key), leaves: this.toLeaves(value, secret.has(key)),
      }));
      this.rows.set(rows.length ? rows : [this.blankRow()]);
    });
  }
  private blankRow(): VarRow { return { key: '', secret: false, leaves: [{ name: '', value: '', kind: 'text' }] }; }

  // ── row / leaf mutations ────────────────────────────────────────────────────
  private patch(i: number, fn: (r: VarRow) => VarRow): void {
    this.rows.update((rs) => rs.map((r, idx) => (idx === i ? fn(r) : r)));
  }
  private patchLeaf(i: number, li: number, fn: (l: Leaf) => Leaf): void {
    this.patch(i, (r) => ({ ...r, leaves: r.leaves.map((l, x) => (x === li ? fn(l) : l)) }));
  }
  addRow(): void { this.rows.update((rs) => [...rs, this.blankRow()]); }
  removeRow(i: number): void { this.rows.update((rs) => rs.filter((_, idx) => idx !== i)); }
  setKey(i: number, v: string): void { this.patch(i, (r) => ({ ...r, key: v })); }

  addLeaf(i: number): void {
    // Growing to ≥2 entries (or adding a name) makes it a list/dict; a secret only
    // makes sense for a single scalar text, so turn it off.
    this.patch(i, (r) => ({ ...r, secret: false, leaves: [...r.leaves, { name: '', value: '', kind: r.leaves[0]?.kind ?? 'text' }] }));
  }
  removeLeaf(i: number, li: number): void { this.patch(i, (r) => ({ ...r, leaves: r.leaves.filter((_, x) => x !== li) })); }
  setLeafName(i: number, li: number, v: string): void { this.patchLeaf(i, li, (l) => ({ ...l, name: v })); }
  setLeafValue(i: number, li: number, v: string): void { this.patchLeaf(i, li, (l) => ({ ...l, value: v })); }
  setLeafKind(i: number, li: number, v: Kind): void {
    this.patchLeaf(i, li, (l) => {
      const next: Leaf = { ...l, kind: v };
      if (v === 'bool' && next.value !== 'true' && next.value !== 'false') next.value = 'false';
      return next;
    });
  }
  toggleSecret(i: number): void {
    this.patch(i, (r) => (this.isScalarText(r) ? { ...r, secret: !r.secret } : r));
  }
  onSecretFocus(i: number, li: number): void {
    this.patchLeaf(i, li, (l) => (this.rows()[i].secret && l.value === MASK ? { ...l, value: '' } : l));
  }

  // ── save ─────────────────────────────────────────────────────────────────────
  private coerce(l: Leaf, ctx: string): unknown {
    if (l.kind === 'number') {
      const n = Number(l.value);
      if (l.value.trim() === '' || Number.isNaN(n)) throw new Error(`${ctx}: "${l.value}" is not a number`);
      return n;
    }
    if (l.kind === 'bool') return l.value === 'true';
    return l.value;
  }

  /** Build the vars object and PUT it. Public so the dialog wrapper can drive it. */
  save(): void {
    this.error.set(''); this.savedMsg.set('');
    const vars: Record<string, unknown> = {};
    const secretKeys: string[] = [];
    try {
      for (const r of this.rows()) {
        const k = r.key.trim();
        if (!k) continue;
        if (r.secret && this.isScalarText(r)) {
          secretKeys.push(k);
          const v = r.leaves[0].value;
          vars[k] = v === '' ? MASK : v;                          // never coerce a secret; mask = unchanged
          continue;
        }
        if (!this.structured(r)) {                                // scalar
          vars[k] = this.coerce(r.leaves[0], `"${k}"`);
          continue;
        }
        const named = r.leaves.filter((l) => l.name.trim() !== '');
        if (named.length) {                                        // dict
          const obj: Record<string, unknown> = {};
          for (const l of named) obj[l.name.trim()] = this.coerce(l, `"${k}.${l.name.trim()}"`);
          vars[k] = obj;
        } else {                                                   // list
          vars[k] = r.leaves.map((l, x) => this.coerce(l, `"${k}"[${x}]`));
        }
      }
    } catch (e) { this.error.set((e as Error).message); return; }

    this.busy.set(true);
    const body: Record<string, unknown> = { scope_type: this.scopeType, vars, secret_keys: secretKeys };
    body[{ ou: 'ou_id', group: 'host_group_id', host: 'agent_id' }[this.scopeType]] = this.scopeId;
    this.http.put(`${this.base}/scope-vars`, body).subscribe({
      next: () => { this.busy.set(false); this.savedMsg.set('Saved.'); this.saved.emit(); },
      error: (e) => { this.busy.set(false); this.error.set(e?.error?.detail ?? 'save failed'); },
    });
  }
}
