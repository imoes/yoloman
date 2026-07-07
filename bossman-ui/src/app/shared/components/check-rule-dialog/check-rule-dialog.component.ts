import { Component, Inject, inject } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatButtonModule } from '@angular/material/button';
import { CheckRule, CheckRuleComparison, CheckRuleInput, CheckRuleScope } from '../../../core/models/monitoring.model';

export interface CheckRuleDialogData {
  rule?: CheckRule;
}

const COMPARISONS: { value: CheckRuleComparison; label: string }[] = [
  { value: 'gt', label: '> greater than' },
  { value: 'lt', label: '< less than' },
  { value: 'ge', label: '>= greater or equal' },
  { value: 'le', label: '<= less or equal' },
  { value: 'eq', label: '== equal' },
  { value: 'ne', label: '!= not equal' },
];

/** Create/edit a CheckMK-style threshold rule (see docs/plan.md's
 * monitoring Block E4) — scope global/group/host, with group rules
 * overridable by host rules (resolve_effective_rule's own precedence). */
@Component({
  selector: 'app-check-rule-dialog',
  standalone: true,
  imports: [
    ReactiveFormsModule,
    MatDialogModule,
    MatFormFieldModule,
    MatInputModule,
    MatSelectModule,
    MatSlideToggleModule,
    MatButtonModule,
  ],
  template: `
    <h2 mat-dialog-title>{{ data.rule ? 'Edit' : 'New' }} check rule</h2>
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
      <div class="bm-threshold-row">
        <mat-form-field appearance="outline">
          <mat-label>Warn threshold</mat-label>
          <input matInput type="number" formControlName="warn_threshold" />
        </mat-form-field>
        <mat-form-field appearance="outline">
          <mat-label>Crit threshold</mat-label>
          <input matInput type="number" formControlName="crit_threshold" />
        </mat-form-field>
      </div>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Scope</mat-label>
        <mat-select formControlName="scope_type">
          <mat-option value="global">Global (every host)</mat-option>
          <mat-option value="group">Group</mat-option>
          <mat-option value="host">Host (overrides group/global)</mat-option>
        </mat-select>
      </mat-form-field>
      @if (form.value.scope_type !== 'global') {
        <mat-form-field appearance="outline" class="bm-full-width">
          <mat-label>{{ form.value.scope_type === 'host' ? 'Host name' : 'Group name' }}</mat-label>
          <input matInput formControlName="scope_value" />
        </mat-form-field>
      }
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Label pin (optional)</mat-label>
        <input matInput formControlName="label_value" placeholder="e.g. /var — a disk mount; blank = all mounts" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Max attempts before hard (optional)</mat-label>
        <input matInput type="number" formControlName="max_attempts" placeholder="blank = default 3; 1 = alert immediately" />
      </mat-form-field>
      <mat-slide-toggle formControlName="enabled">Enabled</mat-slide-toggle>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="save()">Save</button>
    </mat-dialog-actions>
  `,
  styles: [
    `
      .bm-full-width {
        width: 100%;
      }
      .bm-threshold-row {
        display: flex;
        gap: 12px;
      }
      .bm-threshold-row mat-form-field {
        flex: 1;
      }
    `,
  ],
})
export class CheckRuleDialogComponent {
  dialogRef = inject(MatDialogRef<CheckRuleDialogComponent, CheckRuleInput>);
  comparisons = COMPARISONS;

  form = new FormGroup({
    service_name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    metric: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    comparison: new FormControl<CheckRuleComparison>('gt', { nonNullable: true, validators: [Validators.required] }),
    warn_threshold: new FormControl<number | null>(null),
    crit_threshold: new FormControl<number | null>(null),
    scope_type: new FormControl<CheckRuleScope>('global', { nonNullable: true, validators: [Validators.required] }),
    scope_value: new FormControl<string | null>(null),
    label_value: new FormControl<string | null>(null),
    max_attempts: new FormControl<number | null>(null),
    enabled: new FormControl(true, { nonNullable: true }),
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: CheckRuleDialogData) {
    if (data.rule) {
      this.form.patchValue(data.rule);
    }
  }

  save(): void {
    const value = this.form.getRawValue();
    const scopeValue = value.scope_type === 'global' ? null : value.scope_value;
    // Normalise a blank label pin to null (= applies to all mounts).
    const labelValue = value.label_value?.trim() ? value.label_value.trim() : null;
    this.dialogRef.close({ ...value, scope_value: scopeValue, label_value: labelValue });
  }
}
