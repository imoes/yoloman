import { Component, Inject, inject } from '@angular/core';
import { FormControl, ReactiveFormsModule } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatButtonModule } from '@angular/material/button';

export interface AcknowledgeDialogData {
  serviceName: string;
  hostName: string;
}

/** CheckMK's "we know, don't page anyone" acknowledge action (see
 * docs/plan.md's monitoring Block E4) — a one-field comment dialog reused
 * by both the fleet-overview problems table and the full /problems view.
 * Closes with the comment string, or undefined if cancelled. */
@Component({
  selector: 'app-acknowledge-dialog',
  standalone: true,
  imports: [ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>Acknowledge {{ data.serviceName }} on {{ data.hostName }}</h2>
    <mat-dialog-content>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Comment</mat-label>
        <textarea matInput [formControl]="comment" rows="3" placeholder="What's being done about this?"></textarea>
      </mat-form-field>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" (click)="dialogRef.close(comment.value)">Acknowledge</button>
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
export class AcknowledgeDialogComponent {
  dialogRef = inject(MatDialogRef<AcknowledgeDialogComponent>);
  comment = new FormControl('', { nonNullable: true });

  constructor(@Inject(MAT_DIALOG_DATA) public data: AcknowledgeDialogData) {}
}
