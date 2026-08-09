import { Component, Inject, inject } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatAutocompleteModule } from '@angular/material/autocomplete';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatButtonModule } from '@angular/material/button';
import {
  NotificationChannel,
  NotificationRule,
  NotificationRuleInput,
  NotificationScope,
} from '../../../core/models/notification.model';

/** Everything the scope pickers need, plus optional presets for the scope the
 * dialog was opened from (an OU in the console, a host/service in host-detail). */
export interface NotificationOuDialogData {
  rule?: NotificationRule; // edit mode
  // Presets:
  scopeType?: NotificationScope;
  ouId?: string;
  ouPath?: string;
  hostName?: string;
  serviceName?: string;
  planId?: string;
  // Picker sources (loaded by the caller):
  ous?: { id: string; path: string }[];
  groups?: string[];
  hosts?: string[];
  plans?: { id: string; label: string }[];
}

const SCOPES: { value: NotificationScope; label: string }[] = [
  { value: 'global', label: 'Global — every host' },
  { value: 'ou', label: 'OU — a subtree' },
  { value: 'group', label: 'Host group' },
  { value: 'host', label: 'One host' },
  { value: 'service', label: 'One service on a host' },
  { value: 'policy', label: 'A policy (its services)' },
];

/** Create/edit a notification rule with the shared scope model (Block N/P5).
 * A notification fires ADDITIVELY for every event its scope covers — pick who
 * gets told (channel/target) and what it applies to (scope). */
@Component({
  selector: 'app-notification-ou-dialog',
  standalone: true,
  imports: [
    ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule,
    MatSelectModule, MatAutocompleteModule, MatSlideToggleModule, MatButtonModule,
  ],
  template: `
    <h2 mat-dialog-title>{{ data.rule ? 'Edit' : 'New' }} notification</h2>
    <mat-dialog-content [formGroup]="form">
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Name</mat-label>
        <input matInput formControlName="name" placeholder="e.g. German NOC" />
      </mat-form-field>

      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Applies to (scope)</mat-label>
        <mat-select formControlName="scope_type">
          @for (s of scopes; track s.value) { <mat-option [value]="s.value">{{ s.label }}</mat-option> }
        </mat-select>
      </mat-form-field>

      <!-- Scope target, shown per selected scope -->
      @switch (form.controls.scope_type.value) {
        @case ('ou') {
          <mat-form-field appearance="outline" class="bm-full-width">
            <mat-label>OU</mat-label>
            <mat-select formControlName="ou_id">
              @for (o of data.ous ?? []; track o.id) { <mat-option [value]="o.id">{{ o.path }}</mat-option> }
            </mat-select>
          </mat-form-field>
        }
        @case ('group') {
          <mat-form-field appearance="outline" class="bm-full-width">
            <mat-label>Host group</mat-label>
            <input matInput formControlName="scope_value" [matAutocomplete]="gAuto" placeholder="group name" />
            <mat-autocomplete #gAuto="matAutocomplete">
              @for (g of data.groups ?? []; track g) { <mat-option [value]="g">{{ g }}</mat-option> }
            </mat-autocomplete>
          </mat-form-field>
        }
        @case ('host') {
          <mat-form-field appearance="outline" class="bm-full-width">
            <mat-label>Host</mat-label>
            <mat-select formControlName="scope_value">
              @for (h of data.hosts ?? []; track h) { <mat-option [value]="h">{{ h }}</mat-option> }
            </mat-select>
          </mat-form-field>
        }
        @case ('service') {
          <mat-form-field appearance="outline" class="bm-full-width">
            <mat-label>Host</mat-label>
            <mat-select formControlName="scope_value">
              @for (h of data.hosts ?? []; track h) { <mat-option [value]="h">{{ h }}</mat-option> }
            </mat-select>
          </mat-form-field>
          <mat-form-field appearance="outline" class="bm-full-width">
            <mat-label>Service name</mat-label>
            <input matInput formControlName="scope_service_name" placeholder="e.g. Memory" />
          </mat-form-field>
        }
        @case ('policy') {
          <mat-form-field appearance="outline" class="bm-full-width">
            <mat-label>Policy</mat-label>
            <mat-select formControlName="scope_plan_id">
              @for (p of data.plans ?? []; track p.id) { <mat-option [value]="p.id">{{ p.label }}</mat-option> }
            </mat-select>
          </mat-form-field>
        }
      }

      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Channel</mat-label>
        <mat-select formControlName="channel">
          <mat-option value="email">email</mat-option>
          <mat-option value="webhook">webhook</mat-option>
        </mat-select>
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Target</mat-label>
        <input matInput formControlName="target" placeholder="noc@example.com / https://hook" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Minimum state</mat-label>
        <mat-select formControlName="min_state">
          <mat-option value="WARN">WARN</mat-option>
          <mat-option value="CRIT">CRIT</mat-option>
          <mat-option value="UNKNOWN">UNKNOWN</mat-option>
        </mat-select>
      </mat-form-field>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid || !scopeValid()" (click)="save()">
        {{ data.rule ? 'Save' : 'Create' }}
      </button>
    </mat-dialog-actions>
  `,
  styles: [`.bm-full-width { width: 100%; }`],
})
export class NotificationOuDialogComponent {
  dialogRef = inject(MatDialogRef<NotificationOuDialogComponent, NotificationRuleInput>);
  scopes = SCOPES;

  form = new FormGroup({
    name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    scope_type: new FormControl<NotificationScope>('ou', { nonNullable: true, validators: [Validators.required] }),
    ou_id: new FormControl<string | null>(null),
    scope_value: new FormControl<string | null>(null),
    scope_service_name: new FormControl<string | null>(null),
    scope_plan_id: new FormControl<string | null>(null),
    channel: new FormControl<NotificationChannel>('email', { nonNullable: true, validators: [Validators.required] }),
    target: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    min_state: new FormControl<'WARN' | 'CRIT' | 'UNKNOWN'>('WARN', { nonNullable: true }),
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: NotificationOuDialogData) {
    if (data.rule) {
      this.form.patchValue({
        name: data.rule.name,
        scope_type: data.rule.scope_type ?? (data.rule.ou_id ? 'ou' : 'global'),
        ou_id: data.rule.ou_id ?? null,
        scope_value: data.rule.scope_value ?? null,
        scope_service_name: data.rule.scope_service_name ?? null,
        scope_plan_id: data.rule.scope_plan_id ?? null,
        channel: data.rule.channel,
        target: data.rule.target,
        min_state: data.rule.min_state,
      });
    } else {
      // Presets from where the dialog was opened.
      this.form.patchValue({
        scope_type: data.scopeType ?? (data.ouId ? 'ou' : 'global'),
        ou_id: data.ouId ?? null,
        scope_value: data.hostName ?? null,
        scope_service_name: data.serviceName ?? null,
        scope_plan_id: data.planId ?? null,
      });
    }
  }

  /** The scope's required companion field is filled. */
  scopeValid(): boolean {
    const v = this.form.getRawValue();
    switch (v.scope_type) {
      case 'ou':
        return !!v.ou_id;
      case 'group':
      case 'host':
        return !!(v.scope_value || '').trim();
      case 'service':
        return !!(v.scope_value || '').trim() && !!(v.scope_service_name || '').trim();
      case 'policy':
        return !!v.scope_plan_id;
      default:
        return true; // global
    }
  }

  save(): void {
    const v = this.form.getRawValue();
    const st = v.scope_type;
    this.dialogRef.close({
      name: v.name,
      enabled: true,
      on_problem: true,
      on_recovery: true,
      min_state: v.min_state,
      host_filter: null,
      service_filter: null,
      channel: v.channel,
      target: v.target,
      enforced: false,
      link_order: 100,
      scope_type: st,
      ou_id: st === 'ou' ? v.ou_id : null,
      scope_value: st === 'group' || st === 'host' || st === 'service' ? v.scope_value : null,
      scope_service_name: st === 'service' ? v.scope_service_name : null,
      scope_plan_id: st === 'policy' ? v.scope_plan_id : null,
    });
  }
}
