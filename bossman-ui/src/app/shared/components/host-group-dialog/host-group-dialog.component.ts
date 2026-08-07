import { Component, Inject, inject } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
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
  imports: [ReactiveFormsModule, MatDialogModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>{{ data.group ? 'Edit' : 'New' }} host group</h2>
    <mat-dialog-content [formGroup]="form">
      <div class="bm-field">
        <label>Name</label>
        <input class="bm-in" formControlName="name" placeholder="e.g. webservers" />
      </div>
      <div class="bm-field">
        <label>Description</label>
        <input class="bm-in" formControlName="description" />
      </div>
      <div class="bm-field">
        <label>OU (optional)</label>
        <select class="bm-in" formControlName="ou_id">
          <option [ngValue]="null">(none)</option>
          @for (n of data.nodes; track n.id) { <option [ngValue]="n.id">{{ n.path }}</option> }
        </select>
      </div>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="save()">Save</button>
    </mat-dialog-actions>
  `,
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
