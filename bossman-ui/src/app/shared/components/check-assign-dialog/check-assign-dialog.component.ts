import { Component, Inject, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatButtonModule } from '@angular/material/button';
import { CheckCatalogEntry, CheckOption } from '../../../core/models/check.model';
import { CheckService } from '../../../core/services/check.service';

export interface CheckAssignDialogData {
  scopeLabel: string; // e.g. "OU /Databases" or "group web-servers"
}

export interface CheckAssignResult {
  check_name: string;
  parameters: Record<string, unknown>;
}

/** Pick a library check and fill its parameters, to assign it to an OU or
 * group (GPO-style, Block G9-P3). Same param-form-from-options idea as the
 * host Checks tab; the caller supplies the scope. */
@Component({
  selector: 'app-check-assign-dialog',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatSelectModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>Assign a check to {{ data.scopeLabel }}</h2>
    <mat-dialog-content>
      <mat-form-field appearance="outline" class="bm-full">
        <mat-label>Check</mat-label>
        <mat-select [(ngModel)]="pick" (ngModelChange)="onPick($event)">
          @for (c of catalog(); track c.name) {
            <mat-option [value]="c.name">{{ c.name }}{{ c.short_description ? ' — ' + c.short_description : '' }}</mat-option>
          }
        </mat-select>
      </mat-form-field>

      @if (pick()) {
        @for (o of options(); track o.key) {
          <mat-form-field appearance="outline" class="bm-full">
            <mat-label>{{ o.key }}{{ o.spec.required ? ' *' : '' }}</mat-label>
            <input matInput [ngModel]="draft()[o.key]" (ngModelChange)="setDraft(o.key, $event)"
                   [placeholder]="o.spec.description || o.spec.type || ''" />
          </mat-form-field>
        }
        @if (!options().length) {
          <p class="bm-dim">This check has no parameters — assign it as-is.</p>
        }
      }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="!pick()" (click)="save()">Assign</button>
    </mat-dialog-actions>
  `,
  styles: [`.bm-full { width: 100%; } .bm-dim { opacity: 0.7; }`],
})
export class CheckAssignDialogComponent implements OnInit {
  dialogRef = inject(MatDialogRef<CheckAssignDialogComponent, CheckAssignResult>);
  private checkService = inject(CheckService);
  catalog = signal<CheckCatalogEntry[]>([]);
  pick = signal<string>('');
  draft = signal<Record<string, string>>({});

  options = computed<{ key: string; spec: CheckOption }[]>(() => {
    const c = this.catalog().find((x) => x.name === this.pick());
    return c ? Object.entries(c.options || {}).map(([key, spec]) => ({ key, spec })) : [];
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: CheckAssignDialogData) {}

  ngOnInit(): void {
    this.checkService.listChecks().subscribe((r) => this.catalog.set(r.checks));
  }

  onPick(name: string): void {
    this.pick.set(name);
    const c = this.catalog().find((x) => x.name === name);
    const d: Record<string, string> = {};
    for (const [k, spec] of Object.entries(c?.options || {})) {
      if (spec.default !== undefined && spec.default !== null) d[k] = String(spec.default);
    }
    this.draft.set(d);
  }

  setDraft(key: string, value: string): void {
    this.draft.update((d) => ({ ...d, [key]: value }));
  }

  private typedParams(): Record<string, unknown> {
    const c = this.catalog().find((x) => x.name === this.pick());
    const opts = c?.options || {};
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(this.draft())) {
      if (v === '' || v == null) continue;
      const t = (opts[k]?.type || '').toLowerCase();
      if (t === 'int' || t === 'integer') out[k] = parseInt(v, 10);
      else if (t === 'float' || t === 'number') out[k] = parseFloat(v);
      else if (t === 'bool' || t === 'boolean') out[k] = v === 'true' || v === '1' || v === 'yes';
      else out[k] = v;
    }
    return out;
  }

  save(): void {
    if (!this.pick()) return;
    this.dialogRef.close({ check_name: this.pick(), parameters: this.typedParams() });
  }
}
