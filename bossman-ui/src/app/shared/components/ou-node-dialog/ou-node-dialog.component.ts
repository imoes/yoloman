import { Component, Inject, inject } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
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
  imports: [ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatSelectModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>New OU</h2>
    <mat-dialog-content [formGroup]="form">
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Parent OU</mat-label>
        <mat-select formControlName="parent_id">
          <mat-option [value]="null">(root)</mat-option>
          @for (n of data.nodes; track n.id) {
            <mat-option [value]="n.id">{{ n.path }}</mat-option>
          }
        </mat-select>
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Name</mat-label>
        <input matInput formControlName="name" placeholder="e.g. Munich" />
      </mat-form-field>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="save()">Create</button>
    </mat-dialog-actions>
  `,
  styles: [`.bm-full-width { width: 100%; }`],
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
