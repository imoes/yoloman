import { Component, inject } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatButtonModule } from '@angular/material/button';
import { OrchestrationPlanInput, OrchestrationPlanType } from '../../../core/models/orchestration.model';

const PLAN_TYPES: { value: OrchestrationPlanType; label: string }[] = [
  { value: 'role', label: 'Role (e.g. docker_host)' },
  { value: 'cluster', label: 'Cluster (e.g. postgres_cluster)' },
  { value: 'deployment', label: 'Deployment' },
  { value: 'remediation', label: 'Remediation' },
  { value: 'maintenance', label: 'Maintenance' },
  { value: 'bootstrap', label: 'Bootstrap' },
];

/** Create a new orchestration plan (Block L1) — a named, versioned bundle
 * a link attaches to an OU/host/group/global scope. v1 scope: only the
 * generated_monitoring checks are editable here; steps/parameters/
 * requirements stay API-only for now (a documented v1 simplification —
 * see docs/plan.md's L1 block for why). */
@Component({
  selector: 'app-orchestration-plan-dialog',
  standalone: true,
  imports: [ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatSelectModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>New orchestration plan</h2>
    <mat-dialog-content [formGroup]="form">
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Name</mat-label>
        <input matInput formControlName="name" placeholder="e.g. docker_host" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Display name</mat-label>
        <input matInput formControlName="display_name" placeholder="e.g. Docker Host" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Description</mat-label>
        <input matInput formControlName="description" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Type</mat-label>
        <mat-select formControlName="plan_type">
          @for (t of planTypes; track t.value) {
            <mat-option [value]="t.value">{{ t.label }}</mat-option>
          }
        </mat-select>
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Generated monitoring checks (comma-separated)</mat-label>
        <input matInput formControlName="checks" placeholder="e.g. docker_daemon, docker_disk_usage" />
      </mat-form-field>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="save()">Create</button>
    </mat-dialog-actions>
  `,
  styles: [`.bm-full-width { width: 100%; }`],
})
export class OrchestrationPlanDialogComponent {
  dialogRef = inject(MatDialogRef<OrchestrationPlanDialogComponent, OrchestrationPlanInput>);
  planTypes = PLAN_TYPES;

  form = new FormGroup({
    name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    display_name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    description: new FormControl('', { nonNullable: true }),
    plan_type: new FormControl<OrchestrationPlanType>('role', { nonNullable: true, validators: [Validators.required] }),
    checks: new FormControl('', { nonNullable: true }),
  });

  save(): void {
    const value = this.form.getRawValue();
    const checks = value.checks
      .split(',')
      .map((c) => c.trim())
      .filter(Boolean);
    this.dialogRef.close({
      name: value.name,
      display_name: value.display_name,
      description: value.description,
      plan_type: value.plan_type,
      version: { generated_monitoring: { checks, thresholds: {} } },
    });
  }
}
