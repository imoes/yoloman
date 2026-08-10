import { Component, Inject, inject, viewChild } from '@angular/core';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { ScopeVarsEditorComponent } from './scope-vars-editor.component';

export interface ScopeVarsDialogData {
  scopeType: 'ou' | 'group' | 'host';
  scopeId: string; // ou_id | host_group_id | agent_id
  scopeLabel: string; // e.g. "OU /Databases" or "host db01"
}

/**
 * Block G11 — set variables directly on one scope (OU/group/host) as a dialog.
 * The whole editor lives in the reusable ScopeVarsEditorComponent (also embedded
 * in the host Configuration tab); this wrapper only supplies the dialog chrome
 * and drives the editor's save() from the action bar.
 */
@Component({
  selector: 'app-scope-vars-dialog',
  standalone: true,
  imports: [MatDialogModule, MatButtonModule, ScopeVarsEditorComponent],
  template: `
    <h2 mat-dialog-title>Variables — {{ data.scopeLabel }}</h2>
    <mat-dialog-content>
      <app-scope-vars-editor
        [scopeType]="data.scopeType" [scopeId]="data.scopeId" [scopeLabel]="data.scopeLabel"
        (saved)="dialogRef.close(true)" />
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close(false)">Cancel</button>
      <button mat-raised-button color="primary" (click)="editor().save()">Save</button>
    </mat-dialog-actions>
  `,
})
export class ScopeVarsDialogComponent {
  dialogRef = inject(MatDialogRef<ScopeVarsDialogComponent, boolean>);
  editor = viewChild.required(ScopeVarsEditorComponent);
  constructor(@Inject(MAT_DIALOG_DATA) public data: ScopeVarsDialogData) {}
}
