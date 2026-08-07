import { Component, Inject, OnInit, computed, inject, signal } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { toSignal } from '@angular/core/rxjs-interop';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { CheckRule, CheckRuleComparison, CheckRuleInput, MetricCatalogEntry } from '../../../core/models/monitoring.model';
import { MonitoringService } from '../../../core/services/monitoring.service';
import { isStatefulMetric } from '../../metric-kind.util';

export interface ThresholdDialogData {
  /** OU scope (Block L3c) — set for an OU-scoped threshold. */
  ouId?: string;
  ouPath?: string;
  /** Site (subnet) scope — set for a Site-scoped threshold. */
  siteId?: string;
  siteLabel?: string;
  /** Host scope (Block N/P4) — set to create a threshold for one specific
   * host; with `serviceName`/`metric`/`labelValue` it targets one service on
   * that host (the "warn threshold for a service on a host" case). */
  hostName?: string;
  serviceName?: string;
  metric?: string;
  labelValue?: string;
  /** Present = edit mode (Block L3c). */
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

/** Create/edit an OU-scoped threshold (check rule) with a LIVE metric search
 * (Block L3c) — the Metric field autocompletes from the fleet's real metric
 * catalog (bossman/api/monitoring.py metric-catalog), showing human-readable
 * names, so you don't have to guess raw keys like "cpu_pct". */
@Component({
  selector: 'app-threshold-dialog',
  standalone: true,
  imports: [ReactiveFormsModule, MatDialogModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>
      {{ data.rule ? 'Edit' : 'New' }} threshold {{ scopeLabel() }}
    </h2>
    <mat-dialog-content [formGroup]="form">
      <div class="bm-field">
        <label>Metric</label>
        <input class="bm-in" formControlName="metric" list="bm-thr-metrics"
               placeholder="search e.g. CPU, memory, disk…" (change)="onMetricPicked(form.controls.metric.value)" />
        <datalist id="bm-thr-metrics">
          @for (m of filteredMetrics(); track m.metric) {
            <option [value]="m.metric">{{ m.display_name }}{{ m.unit ? ' (' + m.unit + ')' : '' }}</option>
          }
        </datalist>
      </div>
      <div class="bm-field">
        <label>Service name</label>
        <input class="bm-in" formControlName="service_name" placeholder="e.g. CPU load" />
      </div>
      @if (stateful()) {
        <p class="bm-state-note">This is a state check — it alerts on its own when the service isn't in its expected state. There's nothing to compare, so no thresholds apply here.</p>
      } @else {
        <div class="bm-field">
          <label>Comparison</label>
          <select class="bm-in" formControlName="comparison">
            @for (c of comparisons; track c.value) { <option [value]="c.value">{{ c.label }}</option> }
          </select>
        </div>
        <div class="bm-row">
          <div class="bm-field"><label>Warning</label><input class="bm-in" type="number" formControlName="warn_threshold" /></div>
          <div class="bm-field"><label>Critical</label><input class="bm-in" type="number" formControlName="crit_threshold" /></div>
        </div>
      }
      <label class="bm-check"><input type="checkbox" formControlName="enforced" /> Enforced (can't be overridden by more specific scopes)</label>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="save()">{{ data.rule ? 'Save' : 'Create' }}</button>
    </mat-dialog-actions>
  `,
  styles: [
    `
      /* Compact fields — the same smaller input style used across the policy
         editors (gpedit), not Material's large outline form fields. */
      .bm-field { margin: 8px 0; }
      .bm-field label { display: block; font-size: 12px; font-weight: 600; margin-bottom: 3px; opacity: 0.8; }
      .bm-in { width: 100%; padding: 6px 9px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 13px; box-sizing: border-box; }
      .bm-row { display: flex; gap: 12px; }
      .bm-row .bm-field { flex: 1; }
      .bm-check { display: flex; align-items: center; gap: 8px; font-size: 13px; margin-top: 10px; }
      .bm-state-note { opacity: 0.7; font-size: 13px; line-height: 1.5; margin: 0 0 14px; }
    `,
  ],
})
export class ThresholdDialogComponent implements OnInit {
  dialogRef = inject(MatDialogRef<ThresholdDialogComponent, CheckRuleInput>);
  private monitoring = inject(MonitoringService);
  comparisons = COMPARISONS;

  catalog = signal<MetricCatalogEntry[]>([]);
  form = new FormGroup({
    metric: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    service_name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    comparison: new FormControl<CheckRuleComparison>('gt', { nonNullable: true, validators: [Validators.required] }),
    warn_threshold: new FormControl<number | null>(null),
    crit_threshold: new FormControl<number | null>(null),
    enforced: new FormControl(false, { nonNullable: true }),
  });

  // Live filter over the catalog as the user types in the Metric field.
  private metricTerm = toSignal(this.form.controls.metric.valueChanges, { initialValue: '' });
  private serviceTerm = toSignal(this.form.controls.service_name.valueChanges, { initialValue: '' });
  // A state/boolean check (service running, port open) has no threshold to set.
  stateful = computed(() => isStatefulMetric(this.metricTerm(), this.serviceTerm()));
  filteredMetrics = computed(() => {
    const term = (this.metricTerm() || '').toLowerCase();
    const all = this.catalog();
    if (!term) return all.slice(0, 50);
    return all.filter((m) => m.metric.toLowerCase().includes(term) || m.display_name.toLowerCase().includes(term)).slice(0, 50);
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: ThresholdDialogData) {
    if (data.rule) {
      this.form.patchValue({
        metric: data.rule.metric,
        service_name: data.rule.service_name,
        comparison: data.rule.comparison,
        warn_threshold: data.rule.warn_threshold,
        crit_threshold: data.rule.crit_threshold,
        enforced: data.rule.enforced,
      });
    } else if (data.hostName) {
      // Per-service override on a host: pre-fill the metric + a sensible
      // service name from the service the operator clicked.
      this.form.patchValue({
        metric: data.metric ?? '',
        service_name: data.serviceName ?? '',
      });
    }
  }

  ngOnInit(): void {
    this.monitoring.metricCatalog().subscribe((c) => this.catalog.set(c));
  }

  scopeLabel(): string {
    if (this.data.hostName) return 'on host ' + this.data.hostName;
    if (this.data.siteId) return 'in site ' + (this.data.siteLabel ?? '');
    return 'in ' + (this.data.ouPath ?? '');
  }

  onMetricPicked(metric: string): void {
    // Prefill a sensible service name from the metric's display name if empty.
    if (!this.form.controls.service_name.value) {
      const entry = this.catalog().find((m) => m.metric === metric);
      if (entry) this.form.controls.service_name.setValue(entry.display_name);
    }
  }

  save(): void {
    const v = this.form.getRawValue();
    // Host scope (Block P4) vs OU scope. A host-scoped rule beats the OU
    // default for that host via GPO precedence; a labelValue narrows it to
    // one service (e.g. a single disk mount).
    const siteScope = !!this.data.siteId;
    const hostScope = !!this.data.hostName;
    // A state check carries no numeric thresholds — the check's own state logic
    // alerts; persist null warn/crit so no meaningless comparison is stored.
    const st = this.stateful();
    this.dialogRef.close({
      service_name: v.service_name,
      metric: v.metric,
      comparison: v.comparison,
      warn_threshold: st ? null : v.warn_threshold,
      crit_threshold: st ? null : v.crit_threshold,
      scope_type: siteScope ? 'site' : hostScope ? 'host' : 'ou',
      scope_value: hostScope ? this.data.hostName! : null,
      scope_ou_id: siteScope || hostScope ? null : (this.data.ouId ?? null),
      scope_site_id: siteScope ? this.data.siteId! : null,
      enforced: v.enforced,
      link_order: this.data.rule?.link_order ?? 100,
      label_value: this.data.labelValue ?? this.data.rule?.label_value ?? null,
      max_attempts: this.data.rule?.max_attempts ?? null,
      enabled: this.data.rule?.enabled ?? true,
    });
  }
}
