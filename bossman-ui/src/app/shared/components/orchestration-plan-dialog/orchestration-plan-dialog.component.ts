import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormArray, FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatAutocompleteModule } from '@angular/material/autocomplete';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { OrchestrationPlan, OrchestrationPlanInput, OrchestrationPlanType } from '../../../core/models/orchestration.model';
import { MetricCatalogEntry } from '../../../core/models/monitoring.model';
import { MonitoringService } from '../../../core/services/monitoring.service';
import { OrchestrationService } from '../../../core/services/orchestration.service';

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
 * Every entry field has a LIVE search: metrics from the fleet metric catalog,
 * and checks/roles/routes from what existing policies already use. */
@Component({
  selector: 'app-orchestration-plan-dialog',
  standalone: true,
  imports: [
    ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule,
    MatSelectModule, MatAutocompleteModule, MatButtonModule, MatIconModule,
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

      <!-- Thresholds: multiple metric warn/crit entries, metric has live search -->
      <div class="bm-section" formArrayName="thresholds">
        <div class="bm-section-head">
          <span>Thresholds</span>
          <button mat-stroked-button type="button" (click)="addThreshold()">
            <mat-icon>add</mat-icon> Add threshold
          </button>
        </div>
        @for (row of thresholds.controls; track row; let i = $index) {
          <div class="bm-row" [formGroupName]="i">
            <mat-form-field appearance="outline" class="bm-grow">
              <mat-label>Metric</mat-label>
              <input matInput formControlName="metric" [matAutocomplete]="mAuto" placeholder="search e.g. CPU, memory, disk…" />
              <mat-autocomplete #mAuto="matAutocomplete">
                @for (m of filterMetrics(val(row, 'metric')); track m.metric) {
                  <mat-option [value]="m.metric">
                    {{ m.display_name }}<span class="bm-key"> · {{ m.metric }}{{ m.unit ? ' (' + m.unit + ')' : '' }}</span>
                  </mat-option>
                }
              </mat-autocomplete>
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

      <!-- Checks -->
      <div class="bm-section" formArrayName="checks">
        <div class="bm-section-head">
          <span>Checks</span>
          <button mat-stroked-button type="button" (click)="addStr(checks)"><mat-icon>add</mat-icon> Add check</button>
        </div>
        @for (ctrl of checks.controls; track ctrl; let i = $index) {
          <div class="bm-row">
            <mat-form-field appearance="outline" class="bm-grow">
              <mat-label>Check name</mat-label>
              <input matInput [formControlName]="i" [matAutocomplete]="cAuto" placeholder="search e.g. docker_daemon" />
              <mat-autocomplete #cAuto="matAutocomplete">
                @for (s of filterStrings(checkSuggestions(), ctrl.value); track s) { <mat-option [value]="s">{{ s }}</mat-option> }
              </mat-autocomplete>
            </mat-form-field>
            <button mat-icon-button type="button" (click)="checks.removeAt(i)" title="Remove"><mat-icon>delete</mat-icon></button>
          </div>
        }
      </div>

      <!-- Roles / plans -->
      <div class="bm-section" formArrayName="roles">
        <div class="bm-section-head">
          <span>Roles / plans</span>
          <button mat-stroked-button type="button" (click)="addStr(roles)"><mat-icon>add</mat-icon> Add role</button>
        </div>
        @for (ctrl of roles.controls; track ctrl; let i = $index) {
          <div class="bm-row">
            <mat-form-field appearance="outline" class="bm-grow">
              <mat-label>Role / plan name</mat-label>
              <input matInput [formControlName]="i" [matAutocomplete]="rAuto" placeholder="search e.g. docker_host" />
              <mat-autocomplete #rAuto="matAutocomplete">
                @for (s of filterStrings(roleSuggestions(), ctrl.value); track s) { <mat-option [value]="s">{{ s }}</mat-option> }
              </mat-autocomplete>
            </mat-form-field>
            <button mat-icon-button type="button" (click)="roles.removeAt(i)" title="Remove"><mat-icon>delete</mat-icon></button>
          </div>
        }
      </div>

      <!-- Notification routes -->
      <div class="bm-section" formArrayName="notifications">
        <div class="bm-section-head">
          <span>Notification routes</span>
          <button mat-stroked-button type="button" (click)="addStr(notifications)"><mat-icon>add</mat-icon> Add route</button>
        </div>
        @for (ctrl of notifications.controls; track ctrl; let i = $index) {
          <div class="bm-row">
            <mat-form-field appearance="outline" class="bm-grow">
              <mat-label>Route</mat-label>
              <input matInput [formControlName]="i" [matAutocomplete]="nAuto" placeholder="search e.g. email:ops@example.com" />
              <mat-autocomplete #nAuto="matAutocomplete">
                @for (s of filterStrings(routeSuggestions(), ctrl.value); track s) { <mat-option [value]="s">{{ s }}</mat-option> }
              </mat-autocomplete>
            </mat-form-field>
            <button mat-icon-button type="button" (click)="notifications.removeAt(i)" title="Remove"><mat-icon>delete</mat-icon></button>
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
      .bm-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
      .bm-grow { flex: 1 1 180px; min-width: 0; }
      .bm-cmp { width: 84px; }
      .bm-num { width: 90px; }
      .bm-key { opacity: 0.55; font-size: 12px; }
      /* Fill the dialog width without forcing horizontal scroll. */
      mat-dialog-content { width: 100%; box-sizing: border-box; overflow-x: hidden; }
    `,
  ],
})
export class OrchestrationPlanDialogComponent implements OnInit {
  dialogRef = inject(MatDialogRef<OrchestrationPlanDialogComponent, OrchestrationPlanInput>);
  private monitoring = inject(MonitoringService);
  private orchestration = inject(OrchestrationService);
  planTypes = PLAN_TYPES;
  comparisons = COMPARISONS;

  catalog = signal<MetricCatalogEntry[]>([]);
  plans = signal<OrchestrationPlan[]>([]);

  // Live-search suggestion sources derived from what existing policies use,
  // so the same check/role/route vocabulary is reused, not re-typed.
  checkSuggestions = computed(() =>
    this.uniq(this.plans().flatMap((p) => p.versions?.flatMap((v) => v.generated_monitoring?.checks ?? []) ?? [])),
  );
  roleSuggestions = computed(() => {
    const names = this.plans().flatMap((p) => [p.name, p.display_name]);
    const inline = this.plans().flatMap((p) => p.versions?.flatMap((v) => (v.generated_monitoring as { roles?: string[] })?.roles ?? []) ?? []);
    return this.uniq([...names, ...inline]);
  });
  routeSuggestions = computed(() =>
    this.uniq(this.plans().flatMap((p) => p.versions?.flatMap((v) => v.generated_notifications?.routes ?? []) ?? [])),
  );

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

  ngOnInit(): void {
    this.monitoring.metricCatalog().subscribe((c) => this.catalog.set(c));
    this.orchestration.listPlans().subscribe((p) => this.plans.set(p));
  }

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

  /** Read a threshold row control's value for the template autocomplete. */
  val(row: unknown, key: string): string {
    return (row as FormGroup).get(key)?.value ?? '';
  }

  filterMetrics(term: string): MetricCatalogEntry[] {
    const t = (term || '').toLowerCase();
    const all = this.catalog();
    if (!t) return all.slice(0, 50);
    return all.filter((m) => m.metric.toLowerCase().includes(t) || m.display_name.toLowerCase().includes(t)).slice(0, 50);
  }

  filterStrings(all: string[], term: string): string[] {
    const t = (term || '').toLowerCase();
    return (t ? all.filter((s) => s.toLowerCase().includes(t)) : all).slice(0, 50);
  }

  private uniq(xs: string[]): string[] {
    return [...new Set(xs.map((x) => (x || '').trim()).filter(Boolean))].sort();
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

  addStr(arr: FormArray<FormControl<string>>): void {
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
