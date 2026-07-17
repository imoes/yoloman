import { Component, Inject } from '@angular/core';
import { MatDialogModule, MAT_DIALOG_DATA } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { OuConfigEditorComponent, EditorScope } from './ou-config-editor.component';

export interface PolicyGpeditDialogData {
  scope: EditorScope;
}

/**
 * "New Policy" / edit-policy — authors a config policy through the full
 * Miller-column gpedit editor (the new format) instead of the old orchestration
 * form. A config policy is scoped to an OU/group, so the dialog is opened for a
 * selected scope; each setting is applied through the editor's own Apply.
 */
@Component({
  selector: 'app-policy-gpedit-dialog',
  standalone: true,
  imports: [MatDialogModule, MatButtonModule, OuConfigEditorComponent],
  template: `
    <h2 mat-dialog-title>Policy settings — {{ data.scope.label }}</h2>
    <mat-dialog-content>
      <app-ou-config-editor [scope]="data.scope" />
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-flat-button color="primary" mat-dialog-close>Done</button>
    </mat-dialog-actions>
  `,
  styles: [`
    /* Fit the viewport and never scroll sideways — the editor's Miller columns
       wrap on their own when the panel is narrow. */
    mat-dialog-content { width: min(1100px, 88vw); max-width: 88vw; overflow-x: hidden; box-sizing: border-box; }
  `],
})
export class PolicyGpeditDialogComponent {
  constructor(@Inject(MAT_DIALOG_DATA) public data: PolicyGpeditDialogData) {}
}
