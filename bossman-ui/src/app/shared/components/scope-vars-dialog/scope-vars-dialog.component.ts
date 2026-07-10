import { Component, Inject, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../../environments/environment';

export interface ScopeVarsDialogData {
  scopeType: 'ou' | 'group' | 'host';
  scopeId: string; // ou_id | host_group_id | agent_id
  scopeLabel: string; // e.g. "OU /Databases" or "host db01"
}

interface Row { key: string; value: string; }

/**
 * Block G11 — set the variables directly on one scope (OU/group/host). These
 * resolve GPO-style at runbook-run time (group < OU root→leaf < host), so a
 * value set on a parent OU is inherited by its hosts and overridable deeper.
 * Values are stored as strings here; numeric-looking ones are coerced on save
 * so a runbook's ${port} lands as an int, not "5432".
 */
@Component({
  selector: 'app-scope-vars-dialog',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatButtonModule, MatIconModule],
  template: `
    <h2 mat-dialog-title>Variables — {{ data.scopeLabel }}</h2>
    <mat-dialog-content>
      <p class="bm-dim">Set directly on this scope. Resolved GPO-style at run time
        (group &lt; OU root→leaf &lt; host); deeper/host values win.</p>
      @for (r of rows(); track $index) {
        <div class="bm-row">
          <mat-form-field appearance="outline" class="bm-key">
            <mat-label>name</mat-label>
            <input matInput [ngModel]="r.key" (ngModelChange)="setKey($index, $event)" placeholder="mysql_port" />
          </mat-form-field>
          <mat-form-field appearance="outline" class="bm-val">
            <mat-label>value</mat-label>
            <input matInput [ngModel]="r.value" (ngModelChange)="setVal($index, $event)" placeholder="3306" />
          </mat-form-field>
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
    .bm-dim { opacity: 0.7; font-size: 13px; margin-bottom: 8px; max-width: 520px; }
    .bm-err { color: var(--bm-red); }
    .bm-row { display: flex; gap: 8px; align-items: center; }
    .bm-key { width: 200px; } .bm-val { flex: 1; min-width: 220px; }
  `],
})
export class ScopeVarsDialogComponent implements OnInit {
  dialogRef = inject(MatDialogRef<ScopeVarsDialogComponent, boolean>);
  private http = inject(HttpClient);
  private base = environment.apiUrl;
  rows = signal<Row[]>([]);
  error = signal<string>('');

  constructor(@Inject(MAT_DIALOG_DATA) public data: ScopeVarsDialogData) {}

  private idParam(): string {
    const key = { ou: 'ou_id', group: 'host_group_id', host: 'agent_id' }[this.data.scopeType];
    return `${key}=${this.data.scopeId}`;
  }

  ngOnInit(): void {
    this.http.get<{ vars: Record<string, unknown> }>(
      `${this.base}/scope-vars?scope_type=${this.data.scopeType}&${this.idParam()}`,
    ).subscribe((r) => {
      const rows = Object.entries(r.vars || {}).map(([key, value]) => ({ key, value: String(value) }));
      this.rows.set(rows.length ? rows : [{ key: '', value: '' }]);
    });
  }

  add(): void { this.rows.update((r) => [...r, { key: '', value: '' }]); }
  remove(i: number): void { this.rows.update((r) => r.filter((_, idx) => idx !== i)); }
  setKey(i: number, v: string): void { this.rows.update((r) => r.map((row, idx) => (idx === i ? { ...row, key: v } : row))); }
  setVal(i: number, v: string): void { this.rows.update((r) => r.map((row, idx) => (idx === i ? { ...row, value: v } : row))); }

  private coerce(v: string): unknown {
    if (v === 'true' || v === 'false') return v === 'true';
    if (/^-?\d+$/.test(v)) return parseInt(v, 10);
    if (/^-?\d*\.\d+$/.test(v)) return parseFloat(v);
    return v;
  }

  save(): void {
    const vars: Record<string, unknown> = {};
    for (const { key, value } of this.rows()) {
      const k = key.trim();
      if (k) vars[k] = this.coerce(value);
    }
    const body: Record<string, unknown> = { scope_type: this.data.scopeType, vars };
    body[{ ou: 'ou_id', group: 'host_group_id', host: 'agent_id' }[this.data.scopeType]] = this.data.scopeId;
    this.http.put(`${this.base}/scope-vars`, body).subscribe({
      next: () => this.dialogRef.close(true),
      error: (e) => this.error.set(e?.error?.detail ?? 'save failed'),
    });
  }
}
