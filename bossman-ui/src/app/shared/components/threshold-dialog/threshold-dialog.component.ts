import { Component, Inject, OnInit, computed, inject, signal } from '@angular/core';
import { FormControl, FormGroup, FormsModule, ReactiveFormsModule, Validators } from '@angular/forms';
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

/** Create/edit an OU/Site/host-scoped threshold (check rule), Block L3c. The
 * metric is chosen from a MILLER-STYLE browser (design philosophy, R6): a
 * searchable list on the left where each metric shows its human-readable name
 * with a one-line description in smaller text underneath (from the fleet's real
 * metric catalog, bossman/api/monitoring.py) — so you don't guess raw keys like
 * "cpu_pct" — and the threshold config (comparison, warn/crit, enforced) renders
 * as compact fields on the right, mirroring the check-assign dialog. */
@Component({
  selector: 'app-threshold-dialog',
  standalone: true,
  imports: [FormsModule, ReactiveFormsModule, MatDialogModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>
      {{ data.rule ? 'Edit' : 'New' }} threshold {{ scopeLabel() }}
    </h2>
    <mat-dialog-content [formGroup]="form">
      <input class="bm-in bm-search" type="search" placeholder="Search metrics — CPU, memory, disk…"
             [ngModel]="search()" [ngModelOptions]="{ standalone: true }" (ngModelChange)="search.set($event)" />
      <div class="bm-browser">
        <div class="bm-list">
          @for (m of filteredMetrics(); track m.metric) {
            <div class="bm-item" [class.sel]="form.controls.metric.value === m.metric"
                 (click)="pick(m)" [title]="m.metric">
              <div class="bm-item-name">{{ m.display_name }}{{ m.unit ? ' (' + m.unit + ')' : '' }}</div>
              @if (m.description) { <div class="bm-item-desc">{{ m.description }}</div> }
            </div>
          } @empty { <p class="bm-dim">No metrics match.</p> }
        </div>
        <div class="bm-params">
          @if (form.controls.metric.value) {
            <div class="bm-params-head">{{ form.controls.metric.value }}</div>
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
          } @else { <p class="bm-dim">Pick a metric on the left.</p> }
        </div>
      </div>
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
      .bm-search { max-width: 100%; margin-bottom: 10px; }
      .bm-browser { display: flex; gap: 12px; min-width: 560px; }
      .bm-list { flex: 0 0 240px; max-height: 360px; overflow-y: auto; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; }
      .bm-item { padding: 6px 10px; cursor: pointer; border-left: 3px solid transparent; }
      .bm-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-item.sel { border-left-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
      .bm-item-name { font-size: 13px; }
      .bm-item-desc { font-size: 11.5px; opacity: 0.6; line-height: 1.35; margin-top: 1px; }
      .bm-params { flex: 1 1 300px; min-width: 0; max-height: 360px; overflow-y: auto; }
      .bm-params-head { font-family: ui-monospace, monospace; font-size: 14px; margin-bottom: 6px; }
      .bm-dim { opacity: 0.7; font-size: 13px; padding: 6px 2px; }
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

  // Miller-list search term (free text over name + raw key + description).
  search = signal('');
  // The selected metric + service name drive the stateful check (no thresholds).
  private metricTerm = toSignal(this.form.controls.metric.valueChanges, { initialValue: '' });
  private serviceTerm = toSignal(this.form.controls.service_name.valueChanges, { initialValue: '' });
  // A state/boolean check (service running, port open) has no threshold to set.
  stateful = computed(() => isStatefulMetric(this.metricTerm(), this.serviceTerm()));
  filteredMetrics = computed(() => {
    const term = this.search().toLowerCase().trim();
    const all = this.catalog();
    if (!term) return all;
    return all.filter(
      (m) =>
        m.metric.toLowerCase().includes(term) ||
        m.display_name.toLowerCase().includes(term) ||
        (m.description || '').toLowerCase().includes(term),
    );
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

  /** Select a metric from the Miller list — sets the form control and prefills a
   * sensible service name from its display name (if the field is still empty). */
  pick(m: MetricCatalogEntry): void {
    this.form.controls.metric.setValue(m.metric);
    if (!this.form.controls.service_name.value) this.form.controls.service_name.setValue(m.display_name);
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
