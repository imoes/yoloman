import { Component, Inject } from '@angular/core';
import { MatDialogModule, MAT_DIALOG_DATA } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
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
  imports: [MatDialogModule, MatButtonModule, MatIconModule, OuConfigEditorComponent],
  template: `
    <h2 mat-dialog-title class="bm-gpd-title">
      <span>Policy settings — {{ data.scope.label }}</span>
      <button mat-icon-button mat-dialog-close aria-label="Close" title="Close">
        <mat-icon>close</mat-icon>
      </button>
    </h2>
    <mat-dialog-content>
      <app-ou-config-editor [scope]="data.scope" />
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <!-- Each setting is applied by its own Apply button in the editor, so there
           is nothing to save/discard on the dialog itself — this just closes. -->
      <button mat-flat-button color="primary" mat-dialog-close>Close</button>
    </mat-dialog-actions>
  `,
  styles: [`
    /* Fit the viewport and never scroll sideways — the editor's Miller columns
       wrap on their own when the panel is narrow. */
    mat-dialog-content { width: 100%; max-width: 100%; overflow-x: hidden; box-sizing: border-box; }
    .bm-gpd-title { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin: 0; }
  `],
})
export class PolicyGpeditDialogComponent {
  constructor(@Inject(MAT_DIALOG_DATA) public data: PolicyGpeditDialogData) {}
}
