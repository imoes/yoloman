import { Component, Inject, inject } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatButtonModule } from '@angular/material/button';
import { HostGroup, HostGroupInput } from '../../../core/models/host-group.model';
import { OUNode } from '../../../core/models/ou.model';

export interface HostGroupDialogData {
  group?: HostGroup;
  nodes: OUNode[];
}

/** Create/edit a first-class host group (Block L1) — placed inside an OU;
 * membership is managed separately (see host-group-members-dialog). */
@Component({
  selector: 'app-host-group-dialog',
  standalone: true,
  imports: [ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatSelectModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>{{ data.group ? 'Edit' : 'New' }} host group</h2>
    <mat-dialog-content [formGroup]="form">
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Name</mat-label>
        <input matInput formControlName="name" placeholder="e.g. webservers" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Description</mat-label>
        <input matInput formControlName="description" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>OU (optional)</mat-label>
        <mat-select formControlName="ou_id">
          <mat-option [value]="null">(none)</mat-option>
          @for (n of data.nodes; track n.id) {
            <mat-option [value]="n.id">{{ n.path }}</mat-option>
          }
        </mat-select>
      </mat-form-field>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="save()">Save</button>
    </mat-dialog-actions>
  `,
  styles: [`.bm-full-width { width: 100%; }`],
})
export class HostGroupDialogComponent {
  dialogRef = inject(MatDialogRef<HostGroupDialogComponent, HostGroupInput>);

  form = new FormGroup({
    name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    description: new FormControl('', { nonNullable: true }),
    ou_id: new FormControl<string | null>(null),
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: HostGroupDialogData) {
    if (data.group) {
      this.form.patchValue(data.group);
    }
  }

  save(): void {
    this.dialogRef.close(this.form.getRawValue());
  }
}
