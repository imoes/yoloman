import { Component, Inject } from '@angular/core';
import { MatDialogModule, MAT_DIALOG_DATA, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';

export interface StagedReviewData {
  /** Ordered labels of the staged operations, exactly as they will run. */
  labels: string[];
}

/**
 * Review-before-Apply: clicking Apply on the draft-mode bar opens this dialog so
 * the operator can read every staged change (in run order) before committing.
 * Returns true to apply, false/undefined to go back and keep editing.
 */
@Component({
  selector: 'app-staged-review-dialog',
  standalone: true,
  imports: [MatDialogModule, MatButtonModule, MatIconModule],
  template: `
    <h2 mat-dialog-title>Review pending changes</h2>
    <mat-dialog-content>
      <p class="bm-sr-hint">
        {{ data.labels.length }} change{{ data.labels.length === 1 ? '' : 's' }} will be applied in this order.
        Nothing has been written yet.
      </p>
      <ol class="bm-sr-list">
        @for (l of data.labels; track $index) {
          <li><span class="bm-sr-n">{{ $index + 1 }}</span><span class="bm-sr-l">{{ l }}</span></li>
        }
      </ol>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close(false)">Back</button>
      <button mat-flat-button color="primary" (click)="dialogRef.close(true)">
        <mat-icon>publish</mat-icon> Apply {{ data.labels.length }} change{{ data.labels.length === 1 ? '' : 's' }}
      </button>
    </mat-dialog-actions>
  `,
  styles: [`
    .bm-sr-hint { font-size: 13px; opacity: 0.75; margin: 0 0 10px; }
    .bm-sr-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; max-height: 50vh; overflow-y: auto; }
    .bm-sr-list li { display: flex; align-items: baseline; gap: 10px; padding: 7px 10px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; font-size: 13px; }
    .bm-sr-n { flex: 0 0 20px; text-align: right; font-variant-numeric: tabular-nums; opacity: 0.55; font-size: 12px; }
    .bm-sr-l { min-width: 0; word-break: break-word; }
  `],
})
export class StagedReviewDialogComponent {
  constructor(
    @Inject(MAT_DIALOG_DATA) public data: StagedReviewData,
    public dialogRef: MatDialogRef<StagedReviewDialogComponent, boolean>,
  ) {}
}
