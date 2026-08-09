import { Component, Inject, inject } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatButtonModule } from '@angular/material/button';

export interface DowntimeDialogData {
  hostName: string;
  serviceName?: string | null;
}

export interface DowntimeDialogResult {
  minutes: number;
  comment: string;
}

/** Schedules a maintenance window starting now (see docs/plan.md's
 * monitoring Block E4) — for one named service, or the whole host if
 * serviceName is omitted, matching CheckMK's own host-vs-service downtime
 * distinction and the MCP schedule_downtime tool's own duration-in-minutes
 * shape. Closes with {minutes, comment}, or undefined if cancelled. */
@Component({
  selector: 'app-downtime-dialog',
  standalone: true,
  imports: [ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>
      Schedule downtime for {{ data.serviceName ? data.serviceName + ' on ' : 'the whole host ' }}{{ data.hostName }}
    </h2>
    <mat-dialog-content [formGroup]="form">
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Duration (minutes)</mat-label>
        <input matInput type="number" formControlName="minutes" min="1" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Comment</mat-label>
        <textarea matInput formControlName="comment" rows="3" placeholder="Why is this expected?"></textarea>
      </mat-form-field>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="confirm()">Schedule</button>
    </mat-dialog-actions>
  `,
  styles: [
    `
      .bm-full-width {
        width: 100%;
      }
    `,
  ],
})
export class DowntimeDialogComponent {
  dialogRef = inject(MatDialogRef<DowntimeDialogComponent, DowntimeDialogResult>);
  form = new FormGroup({
    minutes: new FormControl(60, { nonNullable: true, validators: [Validators.required, Validators.min(1)] }),
    comment: new FormControl('', { nonNullable: true }),
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: DowntimeDialogData) {}

  confirm(): void {
    const value = this.form.getRawValue();
    this.dialogRef.close({ minutes: value.minutes, comment: value.comment });
  }
}
