import { Component, inject } from '@angular/core';
import { FormArray, FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { OrchestrationPlanInput, OrchestrationPlanType } from '../../../core/models/orchestration.model';

const PLAN_TYPES: { value: OrchestrationPlanType; label: string }[] = [
  { value: 'role', label: 'Role (e.g. docker_host)' },
  { value: 'cluster', label: 'Cluster (e.g. postgres_cluster)' },
  { value: 'deployment', label: 'Deployment' },
  { value: 'remediation', label: 'Remediation' },
  { value: 'maintenance', label: 'Maintenance' },
  { value: 'bootstrap', label: 'Bootstrap' },
];

const COMPARISONS = ['gt', 'lt', 'ge', 'le', 'eq', 'ne'];

/** Policy editor (Block L3f) — a Policy is an orchestration plan used the
 * GPO way: ONE named policy bundles MULTIPLE entries (thresholds, checks,
 * roles, notification routes), and linking it to an OU applies them all.
 * This mirrors a Windows GPO holding many settings. The entries are saved
 * into the plan's version (generated_monitoring / generated_notifications),
 * which the compiler already folds into every linked host's desired state. */
@Component({
  selector: 'app-orchestration-plan-dialog',
  standalone: true,
  imports: [
    ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule,
    MatSelectModule, MatButtonModule, MatIconModule,
  ],
  template: `
    <h2 mat-dialog-title>New policy</h2>
    <mat-dialog-content [formGroup]="form">
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Policy name</mat-label>
        <input matInput formControlName="display_name" placeholder="e.g. Docker Host baseline" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Technical name (optional — auto from policy name)</mat-label>
        <input matInput formControlName="name" placeholder="e.g. docker_host" />
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

      <!-- Thresholds: multiple metric warn/crit entries -->
      <div class="bm-section" formArrayName="thresholds">
        <div class="bm-section-head">
          <span>Thresholds</span>
          <button mat-stroked-button type="button" (click)="addThreshold()">
            <mat-icon>add</mat-icon> Add threshold
          </button>
        </div>
        @for (row of thresholds.controls; track row; let i = $index) {
          <div class="bm-row" [formGroupName]="i">
            <mat-form-field appearance="outline" class="bm-metric">
              <mat-label>Metric</mat-label>
              <input matInput formControlName="metric" placeholder="e.g. mem_used_pct" />
            </mat-form-field>
            <mat-form-field appearance="outline" class="bm-cmp">
              <mat-label>Cmp</mat-label>
              <mat-select formControlName="comparison">
                @for (c of comparisons; track c) { <mat-option [value]="c">{{ c }}</mat-option> }
              </mat-select>
            </mat-form-field>
            <mat-form-field appearance="outline" class="bm-num">
              <mat-label>Warn</mat-label>
              <input matInput type="number" formControlName="warn" />
            </mat-form-field>
            <mat-form-field appearance="outline" class="bm-num">
              <mat-label>Crit</mat-label>
              <input matInput type="number" formControlName="crit" />
            </mat-form-field>
            <button mat-icon-button type="button" (click)="thresholds.removeAt(i)" title="Remove">
              <mat-icon>delete</mat-icon>
            </button>
          </div>
        }
      </div>

      <!-- Checks: multiple check names -->
      <div class="bm-section" formArrayName="checks">
        <div class="bm-section-head">
          <span>Checks</span>
          <button mat-stroked-button type="button" (click)="addCh(checks)">
            <mat-icon>add</mat-icon> Add check
          </button>
        </div>
        @for (row of checks.controls; track row; let i = $index) {
          <div class="bm-row">
            <mat-form-field appearance="outline" class="bm-full-width">
              <mat-label>Check name</mat-label>
              <input matInput [formControlName]="i" placeholder="e.g. docker_daemon" />
            </mat-form-field>
            <button mat-icon-button type="button" (click)="checks.removeAt(i)" title="Remove">
              <mat-icon>delete</mat-icon>
            </button>
          </div>
        }
      </div>

      <!-- Roles/plans: multiple role names this policy carries -->
      <div class="bm-section" formArrayName="roles">
        <div class="bm-section-head">
          <span>Roles / plans</span>
          <button mat-stroked-button type="button" (click)="addCh(roles)">
            <mat-icon>add</mat-icon> Add role
          </button>
        </div>
        @for (row of roles.controls; track row; let i = $index) {
          <div class="bm-row">
            <mat-form-field appearance="outline" class="bm-full-width">
              <mat-label>Role / plan name</mat-label>
              <input matInput [formControlName]="i" placeholder="e.g. docker_host" />
            </mat-form-field>
            <button mat-icon-button type="button" (click)="roles.removeAt(i)" title="Remove">
              <mat-icon>delete</mat-icon>
            </button>
          </div>
        }
      </div>

      <!-- Notifications: multiple routes -->
      <div class="bm-section" formArrayName="notifications">
        <div class="bm-section-head">
          <span>Notification routes</span>
          <button mat-stroked-button type="button" (click)="addCh(notifications)">
            <mat-icon>add</mat-icon> Add route
          </button>
        </div>
        @for (row of notifications.controls; track row; let i = $index) {
          <div class="bm-row">
            <mat-form-field appearance="outline" class="bm-full-width">
              <mat-label>Route</mat-label>
              <input matInput [formControlName]="i" placeholder="e.g. email:ops@example.com" />
            </mat-form-field>
            <button mat-icon-button type="button" (click)="notifications.removeAt(i)" title="Remove">
              <mat-icon>delete</mat-icon>
            </button>
          </div>
        }
      </div>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="save()">Create</button>
    </mat-dialog-actions>
  `,
  styles: [
    `
      .bm-full-width { width: 100%; }
      .bm-section { margin: 8px 0 4px; }
      .bm-section-head {
        display: flex; align-items: center; justify-content: space-between;
        font-size: 13px; font-weight: 600; opacity: 0.85; margin: 8px 0 4px;
      }
      .bm-row { display: flex; align-items: center; gap: 8px; }
      .bm-metric { flex: 1 1 auto; }
      .bm-cmp { width: 84px; }
      .bm-num { width: 96px; }
      mat-dialog-content { min-width: 520px; }
    `,
  ],
})
export class OrchestrationPlanDialogComponent {
  dialogRef = inject(MatDialogRef<OrchestrationPlanDialogComponent, OrchestrationPlanInput>);
  planTypes = PLAN_TYPES;
  comparisons = COMPARISONS;

  form = new FormGroup({
    name: new FormControl('', { nonNullable: true }),
    display_name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    description: new FormControl('', { nonNullable: true }),
    plan_type: new FormControl<OrchestrationPlanType>('role', { nonNullable: true, validators: [Validators.required] }),
    thresholds: new FormArray<
      FormGroup<{
        metric: FormControl<string>;
        comparison: FormControl<string>;
        warn: FormControl<number | null>;
        crit: FormControl<number | null>;
      }>
    >([]),
    checks: new FormArray<FormControl<string>>([]),
    roles: new FormArray<FormControl<string>>([]),
    notifications: new FormArray<FormControl<string>>([]),
  });

  get thresholds() {
    return this.form.controls.thresholds;
  }
  get checks() {
    return this.form.controls.checks;
  }
  get roles() {
    return this.form.controls.roles;
  }
  get notifications() {
    return this.form.controls.notifications;
  }

  addThreshold(): void {
    this.thresholds.push(
      new FormGroup({
        metric: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
        comparison: new FormControl('gt', { nonNullable: true }),
        warn: new FormControl<number | null>(null),
        crit: new FormControl<number | null>(null),
      }),
    );
  }

  /** Add a plain string row (checks / roles / notification routes). */
  addCh(arr: FormArray<FormControl<string>>): void {
    arr.push(new FormControl('', { nonNullable: true, validators: [Validators.required] }));
  }

  save(): void {
    const v = this.form.getRawValue();
    const thresholds: Record<string, unknown> = {};
    for (const t of v.thresholds) {
      if (!t.metric.trim()) continue;
      thresholds[t.metric.trim()] = { warn: t.warn, crit: t.crit, comparison: t.comparison };
    }
    const clean = (xs: string[]) => xs.map((x) => x.trim()).filter(Boolean);
    // Technical name defaults to a slug of the policy (display) name, so the
    // user only has to enter one name; distinct policy names yield distinct
    // technical names (the field the server requires to be unique).
    const name =
      v.name.trim() ||
      v.display_name.trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '') ||
      'policy';
    this.dialogRef.close({
      name,
      display_name: v.display_name,
      description: v.description,
      plan_type: v.plan_type,
      version: {
        generated_monitoring: { checks: clean(v.checks), thresholds, roles: clean(v.roles) },
        generated_notifications: { routes: clean(v.notifications) },
      },
    });
  }
}
