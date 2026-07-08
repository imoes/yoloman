import { Component, Inject, inject } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatButtonModule } from '@angular/material/button';
import { NotificationChannel, NotificationRuleInput } from '../../../core/models/notification.model';

export interface NotificationOuDialogData {
  ouId: string;
  ouPath: string;
}

/** Create an OU-scoped notification rule (Block L3a) — inherited down the
 * OU subtree, with GPO `enforced`. */
@Component({
  selector: 'app-notification-ou-dialog',
  standalone: true,
  imports: [ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatSelectModule, MatSlideToggleModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>New notification in {{ data.ouPath }}</h2>
    <mat-dialog-content [formGroup]="form">
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Name</mat-label>
        <input matInput formControlName="name" placeholder="e.g. German NOC" />
      </mat-form-field>
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
      <mat-slide-toggle formControlName="enforced">Enforced</mat-slide-toggle>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="save()">Create</button>
    </mat-dialog-actions>
  `,
  styles: [`.bm-full-width { width: 100%; }`],
})
export class NotificationOuDialogComponent {
  dialogRef = inject(MatDialogRef<NotificationOuDialogComponent, NotificationRuleInput>);

  form = new FormGroup({
    name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    channel: new FormControl<NotificationChannel>('email', { nonNullable: true, validators: [Validators.required] }),
    target: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    min_state: new FormControl<'WARN' | 'CRIT' | 'UNKNOWN'>('WARN', { nonNullable: true }),
    enforced: new FormControl(false, { nonNullable: true }),
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: NotificationOuDialogData) {}

  save(): void {
    const v = this.form.getRawValue();
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
      ou_id: this.data.ouId,
      enforced: v.enforced,
      link_order: 100,
    });
  }
}
