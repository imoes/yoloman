import { Component, Inject, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../../environments/environment';

export interface ScopeVarsDialogData {
  scopeType: 'ou' | 'group' | 'host';
  scopeId: string; // ou_id | host_group_id | agent_id
  scopeLabel: string; // e.g. "OU /Databases" or "host db01"
}

type VarKind = 'text' | 'number' | 'bool' | 'list' | 'dict';
interface Row { key: string; kind: VarKind; value: string; secret: boolean; }
const MASK = '••••••••';

/**
 * Block G11 — set the variables directly on one scope (OU/group/host). These
 * resolve GPO-style at runbook-run time (group < OU root→leaf < host), so a
 * value set on a parent OU is inherited by its hosts and overridable deeper.
 *
 * A variable is not only a scalar: playbook vars are frequently LISTS and DICTS
 * (e.g. `packages: [nginx, git]`, `nginx: {worker_processes: 4}`). Each row picks
 * a type — text / number / bool / list / dict — and list/dict are edited as JSON;
 * the real JSON value is stored (vars is JSONB), so a runbook's `{{ packages }}`
 * lands as an actual list, not a string. Secrets stay scalar strings (encrypted).
 */
@Component({
  selector: 'app-scope-vars-dialog',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatButtonModule, MatIconModule],
  template: `
    <h2 mat-dialog-title>Variables — {{ data.scopeLabel }}</h2>
    <mat-dialog-content>
      <p class="bm-dim">Set directly on this scope. Resolved GPO-style at run time
        (group &lt; OU root→leaf &lt; host); deeper/host values win. Lists &amp; dicts are
        entered as JSON and passed to playbooks as real structures.</p>
      @for (r of rows(); track $index) {
        <div class="bm-row" [class.bm-row-json]="isJson(r.kind)">
          <input class="bm-in bm-key" [ngModel]="r.key" (ngModelChange)="setKey($index, $event)" placeholder="packages" />
          <select class="bm-in bm-type" [ngModel]="r.kind" (ngModelChange)="setKind($index, $event)">
            <option value="text">text</option>
            <option value="number">number</option>
            <option value="bool">bool</option>
            <option value="list">list</option>
            <option value="dict">dict</option>
          </select>
          @if (isJson(r.kind)) {
            <textarea class="bm-in bm-json" rows="4" [ngModel]="r.value" (ngModelChange)="setVal($index, $event)"
                      [placeholder]="jsonPlaceholder(r.kind)"></textarea>
          } @else if (r.kind === 'bool') {
            <select class="bm-in bm-val" [ngModel]="r.value" (ngModelChange)="setVal($index, $event)">
              <option value="true">true</option><option value="false">false</option>
            </select>
          } @else {
            <input class="bm-in bm-val" [type]="r.secret ? 'password' : 'text'" [ngModel]="r.value"
                   (ngModelChange)="setVal($index, $event)" (focus)="onSecretFocus($index)"
                   [placeholder]="r.secret ? '••••••••' : (r.kind === 'number' ? '3306' : 'value')" />
          }
          <button mat-icon-button (click)="toggleSecret($index)" [disabled]="r.kind !== 'text'"
                  [color]="r.secret ? 'primary' : undefined"
                  [title]="r.kind !== 'text' ? 'Only text values can be secret' : (r.secret ? 'Secret — encrypted at rest' : 'Mark as secret (encrypt at rest)')">
            <mat-icon>{{ r.secret ? 'lock' : 'lock_open' }}</mat-icon>
          </button>
          <button mat-icon-button (click)="remove($index)" title="Remove"><mat-icon>close</mat-icon></button>
        </div>
      }
      <button mat-stroked-button (click)="add()"><mat-icon>add</mat-icon> Add variable</button>
      @if (error()) { <p class="bm-err">{{ error() }}</p> }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close(false)">Cancel</button>
      <button mat-raised-button color="primary" (click)="save()">Save</button>
    </mat-dialog-actions>
  `,
  styles: [`
    .bm-dim { opacity: 0.7; font-size: 13px; margin-bottom: 8px; max-width: 560px; }
    .bm-err { color: var(--mat-sys-error, #c62828); }
    .bm-row { display: flex; gap: 8px; align-items: center; margin-bottom: 6px; }
    .bm-row-json { align-items: flex-start; }
    .bm-key { width: 190px; } .bm-type { width: 92px; } .bm-val { flex: 1; min-width: 200px; }
    .bm-json { flex: 1; min-width: 240px; font-family: ui-monospace, monospace; font-size: 12px; resize: vertical; }
    .bm-in { padding: 6px 8px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; box-sizing: border-box; }
  `],
})
export class ScopeVarsDialogComponent implements OnInit {
  dialogRef = inject(MatDialogRef<ScopeVarsDialogComponent, boolean>);
  private http = inject(HttpClient);
  private base = environment.apiUrl;
  rows = signal<Row[]>([]);
  error = signal<string>('');

  constructor(@Inject(MAT_DIALOG_DATA) public data: ScopeVarsDialogData) {}

  isJson(kind: VarKind): boolean { return kind === 'list' || kind === 'dict'; }
  jsonPlaceholder(kind: VarKind): string {
    return kind === 'list' ? '["nginx", "git"]' : '{ "worker_processes": 4 }';
  }

  private idParam(): string {
    const key = { ou: 'ou_id', group: 'host_group_id', host: 'agent_id' }[this.data.scopeType];
    return `${key}=${this.data.scopeId}`;
  }

  /** Infer the editor kind from a stored value (secrets arrive masked = string). */
  private kindOf(value: unknown, secret: boolean): VarKind {
    if (secret) return 'text';
    if (Array.isArray(value)) return 'list';
    if (value !== null && typeof value === 'object') return 'dict';
    if (typeof value === 'boolean') return 'bool';
    if (typeof value === 'number') return 'number';
    return 'text';
  }
  private toRowValue(value: unknown, kind: VarKind): string {
    if (this.isJson(kind)) return JSON.stringify(value ?? (kind === 'list' ? [] : {}), null, 2);
    return String(value);
  }

  ngOnInit(): void {
    this.http.get<{ vars: Record<string, unknown>; secret_keys?: string[] }>(
      `${this.base}/scope-vars?scope_type=${this.data.scopeType}&${this.idParam()}`,
    ).subscribe((r) => {
      const secret = new Set(r.secret_keys || []);
      const rows = Object.entries(r.vars || {}).map(([key, value]) => {
        const kind = this.kindOf(value, secret.has(key));
        return { key, kind, value: this.toRowValue(value, kind), secret: secret.has(key) };
      });
      this.rows.set(rows.length ? rows : [{ key: '', kind: 'text' as VarKind, value: '', secret: false }]);
    });
  }

  add(): void { this.rows.update((r) => [...r, { key: '', kind: 'text', value: '', secret: false }]); }
  remove(i: number): void { this.rows.update((r) => r.filter((_, idx) => idx !== i)); }
  setKey(i: number, v: string): void { this.rows.update((r) => r.map((row, idx) => (idx === i ? { ...row, key: v } : row))); }
  setVal(i: number, v: string): void { this.rows.update((r) => r.map((row, idx) => (idx === i ? { ...row, value: v } : row))); }
  setKind(i: number, v: VarKind): void {
    this.rows.update((r) => r.map((row, idx) => {
      if (idx !== i) return row;
      const next: Row = { ...row, kind: v };
      if (v !== 'text') next.secret = false;                 // only text can be secret
      if (v === 'bool' && next.value !== 'true' && next.value !== 'false') next.value = 'false';
      if (this.isJson(v) && !next.value.trim()) next.value = v === 'list' ? '[]' : '{}';
      return next;
    }));
  }
  toggleSecret(i: number): void { this.rows.update((r) => r.map((row, idx) => (idx === i && row.kind === 'text' ? { ...row, secret: !row.secret } : row))); }

  onSecretFocus(i: number): void {
    this.rows.update((r) => r.map((row, idx) => (idx === i && row.secret && row.value === MASK ? { ...row, value: '' } : row)));
  }

  save(): void {
    this.error.set('');
    const vars: Record<string, unknown> = {};
    const secretKeys: string[] = [];
    for (const { key, kind, value, secret } of this.rows()) {
      const k = key.trim();
      if (!k) continue;
      if (secret) {
        secretKeys.push(k);
        vars[k] = value === '' ? MASK : value;              // never coerce a secret; mask = unchanged
        continue;
      }
      if (kind === 'number') {
        const n = Number(value);
        if (value.trim() === '' || Number.isNaN(n)) { this.error.set(`"${k}": not a number`); return; }
        vars[k] = n;
      } else if (kind === 'bool') {
        vars[k] = value === 'true';
      } else if (this.isJson(kind)) {
        let parsed: unknown;
        try { parsed = JSON.parse(value); } catch { this.error.set(`"${k}": invalid JSON`); return; }
        const ok = kind === 'list' ? Array.isArray(parsed) : (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed));
        if (!ok) { this.error.set(`"${k}": expected a ${kind === 'list' ? 'JSON array' : 'JSON object'}`); return; }
        vars[k] = parsed;
      } else {
        vars[k] = value;                                     // text stays a string (no silent coercion)
      }
    }
    const body: Record<string, unknown> = { scope_type: this.data.scopeType, vars, secret_keys: secretKeys };
    body[{ ou: 'ou_id', group: 'host_group_id', host: 'agent_id' }[this.data.scopeType]] = this.data.scopeId;
    this.http.put(`${this.base}/scope-vars`, body).subscribe({
      next: () => this.dialogRef.close(true),
      error: (e) => this.error.set(e?.error?.detail ?? 'save failed'),
    });
  }
}
