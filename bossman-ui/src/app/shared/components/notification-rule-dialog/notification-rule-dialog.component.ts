import { Component, Inject, inject } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatButtonModule } from '@angular/material/button';
import { NotificationChannel, NotificationRule, NotificationRuleInput } from '../../../core/models/notification.model';

export interface NotificationRuleDialogData {
  rule?: NotificationRule;
}

/** Create/edit a notification rule (Block H8): who gets told, on which
 * channel, when a service has a confirmed problem/recovery. */
@Component({
  selector: 'app-notification-rule-dialog',
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
    <h2 mat-dialog-title>{{ data.rule ? 'Edit' : 'New' }} notification rule</h2>
    <mat-dialog-content [formGroup]="form">
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Name</mat-label>
        <input matInput formControlName="name" placeholder="e.g. Ops on-call email" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Channel</mat-label>
        <mat-select formControlName="channel">
          <mat-option value="email">Email (SMTP)</mat-option>
          <mat-option value="webhook">Webhook (Slack/Mattermost/generic)</mat-option>
        </mat-select>
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>{{ form.value.channel === 'webhook' ? 'Webhook URL' : 'Email address(es)' }}</mat-label>
        <input matInput formControlName="target" [placeholder]="form.value.channel === 'webhook' ? 'https://hooks.slack.com/…' : 'ops@example.com, oncall@example.com'" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Notify from severity</mat-label>
        <mat-select formControlName="min_state">
          <mat-option value="WARN">Warning and above</mat-option>
          <mat-option value="CRIT">Critical only</mat-option>
          <mat-option value="UNKNOWN">Unknown and above</mat-option>
        </mat-select>
      </mat-form-field>
      <div class="bm-toggle-row">
        <mat-slide-toggle formControlName="on_problem">On problem</mat-slide-toggle>
        <mat-slide-toggle formControlName="on_recovery">On recovery</mat-slide-toggle>
      </div>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Host filter (optional, substring)</mat-label>
        <input matInput formControlName="host_filter" placeholder="e.g. web — blank = all hosts" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Service filter (optional, substring)</mat-label>
        <input matInput formControlName="service_filter" placeholder="e.g. Disk — blank = all services" />
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
      .bm-toggle-row {
        display: flex;
        gap: 24px;
        margin: 4px 0 16px;
      }
    `,
  ],
})
export class NotificationRuleDialogComponent {
  dialogRef = inject(MatDialogRef<NotificationRuleDialogComponent, NotificationRuleInput>);

  form = new FormGroup({
    name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    channel: new FormControl<NotificationChannel>('email', { nonNullable: true }),
    target: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    min_state: new FormControl<'WARN' | 'CRIT' | 'UNKNOWN'>('WARN', { nonNullable: true }),
    on_problem: new FormControl(true, { nonNullable: true }),
    on_recovery: new FormControl(true, { nonNullable: true }),
    host_filter: new FormControl<string | null>(null),
    service_filter: new FormControl<string | null>(null),
    enabled: new FormControl(true, { nonNullable: true }),
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: NotificationRuleDialogData) {
    if (data.rule) {
      this.form.patchValue(data.rule);
    }
  }

  save(): void {
    const v = this.form.getRawValue();
    this.dialogRef.close({
      ...v,
      host_filter: v.host_filter?.trim() ? v.host_filter.trim() : null,
      service_filter: v.service_filter?.trim() ? v.service_filter.trim() : null,
    });
  }
}
