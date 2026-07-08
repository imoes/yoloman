import { Component, Inject, inject } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatButtonModule } from '@angular/material/button';
import { CheckRuleComparison, CheckRuleInput } from '../../../core/models/monitoring.model';

export interface ThresholdDialogData {
  ouId: string;
  ouPath: string;
}

const COMPARISONS: { value: CheckRuleComparison; label: string }[] = [
  { value: 'gt', label: '> greater than' },
  { value: 'lt', label: '< less than' },
  { value: 'ge', label: '>= greater or equal' },
  { value: 'le', label: '<= less or equal' },
  { value: 'eq', label: '== equal' },
  { value: 'ne', label: '!= not equal' },
];

/** Create an OU-scoped threshold (check rule) — "Criticality" in the user's
 * terms (Block L3a). Produces a CheckRuleInput pinned to this OU with GPO
 * `enforced`; the OU tree console sets scope_type='ou' + scope_ou_id. */
@Component({
  selector: 'app-threshold-dialog',
  standalone: true,
  imports: [ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatSelectModule, MatSlideToggleModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>New threshold in {{ data.ouPath }}</h2>
    <mat-dialog-content [formGroup]="form">
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Service name</mat-label>
        <input matInput formControlName="service_name" placeholder="e.g. CPU load" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Metric</mat-label>
        <input matInput formControlName="metric" placeholder="e.g. cpu_pct" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Comparison</mat-label>
        <mat-select formControlName="comparison">
          @for (c of comparisons; track c.value) {
            <mat-option [value]="c.value">{{ c.label }}</mat-option>
          }
        </mat-select>
      </mat-form-field>
      <div class="bm-row">
        <mat-form-field appearance="outline">
          <mat-label>Warning</mat-label>
          <input matInput type="number" formControlName="warn_threshold" />
        </mat-form-field>
        <mat-form-field appearance="outline">
          <mat-label>Critical</mat-label>
          <input matInput type="number" formControlName="crit_threshold" />
        </mat-form-field>
      </div>
      <mat-slide-toggle formControlName="enforced">Enforced (can't be overridden by child OUs)</mat-slide-toggle>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="save()">Create</button>
    </mat-dialog-actions>
  `,
  styles: [
    `
      .bm-full-width { width: 100%; }
      .bm-row { display: flex; gap: 12px; }
      .bm-row mat-form-field { flex: 1; }
    `,
  ],
})
export class ThresholdDialogComponent {
  dialogRef = inject(MatDialogRef<ThresholdDialogComponent, CheckRuleInput>);
  comparisons = COMPARISONS;

  form = new FormGroup({
    service_name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    metric: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    comparison: new FormControl<CheckRuleComparison>('gt', { nonNullable: true, validators: [Validators.required] }),
    warn_threshold: new FormControl<number | null>(null),
    crit_threshold: new FormControl<number | null>(null),
    enforced: new FormControl(false, { nonNullable: true }),
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: ThresholdDialogData) {}

  save(): void {
    const v = this.form.getRawValue();
    this.dialogRef.close({
      service_name: v.service_name,
      metric: v.metric,
      comparison: v.comparison,
      warn_threshold: v.warn_threshold,
      crit_threshold: v.crit_threshold,
      scope_type: 'ou',
      scope_value: null,
      scope_ou_id: this.data.ouId,
      enforced: v.enforced,
      link_order: 100,
      label_value: null,
      max_attempts: null,
      enabled: true,
    });
  }
}
