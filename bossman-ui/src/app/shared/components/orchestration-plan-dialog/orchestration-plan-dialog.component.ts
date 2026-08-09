import { Component, Inject, OnInit, Optional, computed, inject, signal } from '@angular/core';
import { FormArray, FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MatDialogModule, MatDialogRef, MAT_DIALOG_DATA } from '@angular/material/dialog';
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
  imports: [ReactiveFormsModule, MatDialogModule, MatButtonModule, MatIconModule],
  template: `
    <h2 mat-dialog-title>{{ editing ? 'Edit policy' : 'New policy' }}</h2>
    <mat-dialog-content [formGroup]="form">
      <div class="bm-field">
        <label>Policy name</label>
        <input class="bm-in" formControlName="display_name" placeholder="e.g. Docker Host baseline" />
      </div>
      <div class="bm-field">
        <label>Technical name (optional — auto from policy name)</label>
        <input class="bm-in" formControlName="name" placeholder="e.g. docker_host" />
      </div>
      <div class="bm-field">
        <label>Description</label>
        <input class="bm-in" formControlName="description" />
      </div>
      <div class="bm-field">
        <label>Type</label>
        <select class="bm-in" formControlName="plan_type">
          @for (t of planTypes; track t.value) { <option [value]="t.value">{{ t.label }}</option> }
        </select>
      </div>

      <!-- Thresholds: metric (datalist search) + comparison + warn/crit -->
      <div class="bm-section" formArrayName="thresholds">
        <div class="bm-section-head">
          <span>Thresholds</span>
          <button mat-stroked-button type="button" (click)="addThreshold()"><mat-icon>add</mat-icon> Add threshold</button>
        </div>
        @for (row of thresholds.controls; track row; let i = $index) {
          <div class="bm-row" [formGroupName]="i">
            <input class="bm-in bm-grow" formControlName="metric" list="bm-plan-metrics" placeholder="metric e.g. cpu_pct" />
            <select class="bm-in bm-cmp" formControlName="comparison">
              @for (c of comparisons; track c) { <option [value]="c">{{ c }}</option> }
            </select>
            <input class="bm-in bm-num" type="number" formControlName="warn" placeholder="warn" />
            <input class="bm-in bm-num" type="number" formControlName="crit" placeholder="crit" />
            <button mat-icon-button type="button" (click)="thresholds.removeAt(i)" title="Remove"><mat-icon>delete</mat-icon></button>
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
            <input class="bm-in bm-grow" [formControlName]="i" list="bm-plan-checks" placeholder="search e.g. docker_daemon" />
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
            <input class="bm-in bm-grow" [formControlName]="i" list="bm-plan-roles" placeholder="search e.g. docker_host" />
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
            <input class="bm-in bm-grow" [formControlName]="i" list="bm-plan-routes" placeholder="search e.g. email:ops@example.com" />
            <button mat-icon-button type="button" (click)="notifications.removeAt(i)" title="Remove"><mat-icon>delete</mat-icon></button>
          </div>
        }
      </div>

      <datalist id="bm-plan-metrics">@for (m of filterMetrics(''); track m.metric) { <option [value]="m.metric">{{ m.display_name }}{{ m.unit ? ' (' + m.unit + ')' : '' }}</option> }</datalist>
      <datalist id="bm-plan-checks">@for (s of checkSuggestions(); track s) { <option [value]="s"></option> }</datalist>
      <datalist id="bm-plan-roles">@for (s of roleSuggestions(); track s) { <option [value]="s"></option> }</datalist>
      <datalist id="bm-plan-routes">@for (s of routeSuggestions(); track s) { <option [value]="s"></option> }</datalist>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="save()">{{ editing ? 'Save' : 'Create' }}</button>
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
      /* Row inputs size by flex, not the global .bm-in width:100%. */
      .bm-row .bm-in { width: auto; }
      .bm-grow { flex: 1 1 180px; min-width: 0; }
      .bm-cmp { flex: 0 0 84px; }
      .bm-num { flex: 0 0 90px; }
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

  // Edit mode: opened with { plan } to author a NEW VERSION of an existing
  // policy (its entries), not just create one. Rename happens here too (the
  // display name is an editable field), replacing the old rename-only prompt.
  editing = false;
  constructor(@Optional() @Inject(MAT_DIALOG_DATA) public data?: { plan?: OrchestrationPlan }) {}

  ngOnInit(): void {
    this.monitoring.metricCatalog().subscribe((c) => this.catalog.set(c));
    this.orchestration.listPlans().subscribe((p) => this.plans.set(p));
    const plan = this.data?.plan;
    if (plan) this.prefill(plan);
  }

  /** Load an existing policy's identity + its current version's entries into
   * the form so the user edits content, then saves a new version. */
  private prefill(plan: OrchestrationPlan): void {
    this.editing = true;
    this.form.patchValue({
      name: plan.name,
      display_name: plan.display_name,
      description: plan.description ?? '',
      plan_type: plan.plan_type,
    });
    // The technical name is the policy's identity — an edit must not rename it.
    this.form.controls.name.disable();
    const ver =
      plan.versions?.find((v) => v.version === plan.current_version) ??
      plan.versions?.[plan.versions.length - 1];
    if (!ver) return;
    const gm = (ver.generated_monitoring ?? {}) as {
      checks?: string[];
      thresholds?: Record<string, { warn?: number | null; crit?: number | null; comparison?: string }>;
      roles?: string[];
    };
    for (const [metric, t] of Object.entries(gm.thresholds ?? {})) {
      this.thresholds.push(
        new FormGroup({
          metric: new FormControl(metric, { nonNullable: true, validators: [Validators.required] }),
          comparison: new FormControl(t?.comparison ?? 'gt', { nonNullable: true }),
          warn: new FormControl<number | null>(t?.warn ?? null),
          crit: new FormControl<number | null>(t?.crit ?? null),
        }),
      );
    }
    for (const c of gm.checks ?? []) this.checks.push(new FormControl(c, { nonNullable: true, validators: [Validators.required] }));
    for (const r of gm.roles ?? []) this.roles.push(new FormControl(r, { nonNullable: true, validators: [Validators.required] }));
    for (const rt of ver.generated_notifications?.routes ?? []) this.notifications.push(new FormControl(rt, { nonNullable: true, validators: [Validators.required] }));
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
