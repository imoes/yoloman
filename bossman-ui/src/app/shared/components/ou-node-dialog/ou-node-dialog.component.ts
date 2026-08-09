import { Component, Inject, inject } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { OUNode, OUNodeInput } from '../../../core/models/ou.model';

export interface OuNodeDialogData {
  nodes: OUNode[];
}

/** Create a new OU node (Block L1) — placed under an existing node or at
 * the tenant root. Nodes are never edited/renamed in v1 (a rename would
 * shift every descendant's materialized path); delete-and-recreate is the
 * v1 path for a mistake. */
@Component({
  selector: 'app-ou-node-dialog',
  standalone: true,
  imports: [ReactiveFormsModule, MatDialogModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>New OU</h2>
    <mat-dialog-content [formGroup]="form">
      <div class="bm-field">
        <label>Parent OU</label>
        <select class="bm-in" formControlName="parent_id">
          <option [ngValue]="null">(root)</option>
          @for (n of data.nodes; track n.id) { <option [ngValue]="n.id">{{ n.path }}</option> }
        </select>
      </div>
      <div class="bm-field">
        <label>Name</label>
        <input class="bm-in" formControlName="name" placeholder="e.g. Munich" />
      </div>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="save()">Create</button>
    </mat-dialog-actions>
  `,
})
export class OuNodeDialogComponent {
  dialogRef = inject(MatDialogRef<OuNodeDialogComponent, OUNodeInput>);

  form = new FormGroup({
    parent_id: new FormControl<string | null>(null),
    name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: OuNodeDialogData) {}

  save(): void {
    this.dialogRef.close(this.form.getRawValue());
  }
}
