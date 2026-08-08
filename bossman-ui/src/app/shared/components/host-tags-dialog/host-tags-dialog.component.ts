import { Component, Inject, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../../environments/environment';

export interface HostTagsDialogData {
  agentId: string;
  hostName: string;
}

interface Row { key: string; value: string; }

/**
 * Set a host's tags (group:value). Host tags are a match dimension for rule
 * conditions (host_tags) — setting one here is a direct way to make a host pick
 * up every policy/threshold/check whose condition targets that tag. Replaces the
 * whole tag set (PATCH /agents/{id}/tags), mirroring the server's replace shape.
 * An empty value = a name-only tag.
 */
@Component({
  selector: 'app-host-tags-dialog',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatButtonModule, MatIconModule],
  template: `
    <h2 mat-dialog-title>Tags — {{ data.hostName }}</h2>
    <mat-dialog-content>
      <p class="bm-dim">Host tags (group : value). Used by rule conditions
        (<code>host_tags</code>) and problem/notification tag filters — a tag here
        makes this host match every policy scoped to it.</p>
      @for (r of rows(); track $index) {
        <div class="bm-row">
          <input class="bm-in bm-key" [ngModel]="r.key" (ngModelChange)="setKey($index, $event)" placeholder="env" />
          <span class="bm-sep">:</span>
          <input class="bm-in bm-val" [ngModel]="r.value" (ngModelChange)="setVal($index, $event)" placeholder="prod (empty = name-only)" />
          <button mat-icon-button (click)="remove($index)" title="Remove"><mat-icon>close</mat-icon></button>
        </div>
      }
      <button mat-stroked-button (click)="add()"><mat-icon>add</mat-icon> Add tag</button>
      @if (error()) { <p class="bm-err">{{ error() }}</p> }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close(false)">Cancel</button>
      <button mat-raised-button color="primary" (click)="save()">Save</button>
    </mat-dialog-actions>
  `,
  styles: [`
    .bm-dim { opacity: 0.7; font-size: 13px; margin-bottom: 8px; max-width: 520px; }
    .bm-dim code { font-family: ui-monospace, monospace; }
    .bm-err { color: var(--mat-sys-error); }
    .bm-row { display: flex; gap: 8px; align-items: center; }
    .bm-key { width: 180px; } .bm-val { flex: 1; min-width: 200px; }
    .bm-sep { opacity: 0.6; }
    .bm-in { padding: 6px 9px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 13px; }
  `],
})
export class HostTagsDialogComponent implements OnInit {
  dialogRef = inject(MatDialogRef<HostTagsDialogComponent, boolean>);
  private http = inject(HttpClient);
  private base = environment.apiUrl;
  rows = signal<Row[]>([]);
  error = signal<string>('');

  constructor(@Inject(MAT_DIALOG_DATA) public data: HostTagsDialogData) {}

  ngOnInit(): void {
    this.http.get<{ id: string; tags?: Record<string, string> }>(`${this.base}/agents/${this.data.agentId}`).subscribe({
      next: (a) => {
        const rows = Object.entries(a.tags || {}).map(([key, value]) => ({ key, value: String(value ?? '') }));
        this.rows.set(rows.length ? rows : [{ key: '', value: '' }]);
      },
      error: () => this.rows.set([{ key: '', value: '' }]),
    });
  }

  add(): void { this.rows.update((r) => [...r, { key: '', value: '' }]); }
  remove(i: number): void { this.rows.update((r) => r.filter((_, idx) => idx !== i)); }
  setKey(i: number, v: string): void { this.rows.update((r) => r.map((x, idx) => (idx === i ? { ...x, key: v } : x))); }
  setVal(i: number, v: string): void { this.rows.update((r) => r.map((x, idx) => (idx === i ? { ...x, value: v } : x))); }

  save(): void {
    const tags: Record<string, string> = {};
    for (const r of this.rows()) {
      const k = r.key.trim();
      if (k) tags[k] = r.value.trim();
    }
    this.http.patch(`${this.base}/agents/${this.data.agentId}/tags`, { tags }).subscribe({
      next: () => this.dialogRef.close(true),
      error: (e: { error?: { detail?: string } }) => this.error.set(e?.error?.detail ?? 'save failed'),
    });
  }
}
