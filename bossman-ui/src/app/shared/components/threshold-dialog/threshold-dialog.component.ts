import { Component, Inject, OnInit, computed, inject, signal } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { toSignal } from '@angular/core/rxjs-interop';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatAutocompleteModule } from '@angular/material/autocomplete';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatButtonModule } from '@angular/material/button';
import { CheckRule, CheckRuleComparison, CheckRuleInput, MetricCatalogEntry } from '../../../core/models/monitoring.model';
import { MonitoringService } from '../../../core/services/monitoring.service';

export interface ThresholdDialogData {
  ouId: string;
  ouPath: string;
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
  imports: [ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatSelectModule, MatAutocompleteModule, MatSlideToggleModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>{{ data.rule ? 'Edit' : 'New' }} threshold in {{ data.ouPath }}</h2>
    <mat-dialog-content [formGroup]="form">
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Metric</mat-label>
        <input matInput formControlName="metric" [matAutocomplete]="auto" placeholder="search e.g. CPU, memory, disk…" />
        <mat-autocomplete #auto="matAutocomplete" (optionSelected)="onMetricPicked($event.option.value)">
          @for (m of filteredMetrics(); track m.metric) {
            <mat-option [value]="m.metric">
              {{ m.display_name }}<span class="bm-metric-key"> · {{ m.metric }}{{ m.unit ? ' (' + m.unit + ')' : '' }}</span>
            </mat-option>
          }
        </mat-autocomplete>
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Service name</mat-label>
        <input matInput formControlName="service_name" placeholder="e.g. CPU load" />
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
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="save()">{{ data.rule ? 'Save' : 'Create' }}</button>
    </mat-dialog-actions>
  `,
  styles: [
    `
      .bm-full-width { width: 100%; }
      .bm-row { display: flex; gap: 12px; }
      .bm-row mat-form-field { flex: 1; }
      .bm-metric-key { opacity: 0.55; font-size: 12px; }
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
    }
  }

  ngOnInit(): void {
    this.monitoring.metricCatalog().subscribe((c) => this.catalog.set(c));
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
      link_order: this.data.rule?.link_order ?? 100,
      label_value: this.data.rule?.label_value ?? null,
      max_attempts: this.data.rule?.max_attempts ?? null,
      enabled: this.data.rule?.enabled ?? true,
    });
  }
}
