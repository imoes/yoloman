import { Component, Inject, inject } from '@angular/core';
import { FormControl, ReactiveFormsModule } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatButtonModule } from '@angular/material/button';

export interface AcknowledgeDialogData {
  serviceName: string;
  hostName: string;
}

/** The dialog's result: the comment plus an optional expiry in minutes
 * (CheckMK's "acknowledge for a limited time" — Block H5). null minutes =
 * indefinite (valid until the next state change). */
export interface AcknowledgeDialogResult {
  comment: string;
  expireAfterMinutes: number | null;
}

/** CheckMK's "we know, don't page anyone" acknowledge action (see
 * docs/plan.md's monitoring Block E4/H5) — a comment plus a duration so
 * the ack auto-expires and the problem resurfaces. Reused by the
 * fleet-overview problems table, the /problems view, and host detail.
 * Closes with an AcknowledgeDialogResult, or undefined if cancelled. */
@Component({
  selector: 'app-acknowledge-dialog',
  standalone: true,
  imports: [ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatSelectModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>Acknowledge {{ data.serviceName }} on {{ data.hostName }}</h2>
    <mat-dialog-content>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Comment</mat-label>
        <textarea matInput [formControl]="comment" rows="3" placeholder="What's being done about this?"></textarea>
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Acknowledge for</mat-label>
        <mat-select [formControl]="expiry">
          <mat-option [value]="null">Indefinitely (until next state change)</mat-option>
          <mat-option [value]="60">1 hour</mat-option>
          <mat-option [value]="240">4 hours</mat-option>
          <mat-option [value]="1440">1 day</mat-option>
          <mat-option [value]="10080">1 week</mat-option>
        </mat-select>
      </mat-form-field>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" (click)="confirm()">Acknowledge</button>
    </mat-dialog-actions>
  `,
  styles: [
    `
      .bm-full-width {
        width: 100%;
        display: block;
        margin-bottom: 4px;
      }
    `,
  ],
})
export class AcknowledgeDialogComponent {
  dialogRef = inject(MatDialogRef<AcknowledgeDialogComponent, AcknowledgeDialogResult>);
  comment = new FormControl('', { nonNullable: true });
  expiry = new FormControl<number | null>(null);

  constructor(@Inject(MAT_DIALOG_DATA) public data: AcknowledgeDialogData) {}

  confirm(): void {
    this.dialogRef.close({ comment: this.comment.value, expireAfterMinutes: this.expiry.value });
  }
}
