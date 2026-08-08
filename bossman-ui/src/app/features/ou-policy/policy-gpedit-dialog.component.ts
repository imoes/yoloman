import { Component, Inject, ViewChild, signal } from '@angular/core';
import { MatDialogModule, MAT_DIALOG_DATA, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { OuConfigEditorComponent, EditorScope } from './ou-config-editor.component';

export interface PolicyGpeditDialogData {
  scope: EditorScope;
  /** Open directly on this config file (when editing a specific policy). */
  path?: string;
}

/**
 * "New Policy" / edit-policy — authors a config policy through the full
 * Miller-column gpedit editor (the new format). The editor runs in DEFERRED
 * mode: each setting is staged (not written on its own Apply), and the dialog's
 * Save commits them all at once while Cancel discards them — the same
 * Save/Cancel contract as the threshold dialog, instead of a bare Close.
 */
@Component({
  selector: 'app-policy-gpedit-dialog',
  standalone: true,
  imports: [MatDialogModule, MatButtonModule, MatIconModule, OuConfigEditorComponent],
  template: `
    <h2 mat-dialog-title class="bm-gpd-title">
      <span>Policy settings — {{ data.scope.label }}</span>
      <button mat-icon-button (click)="cancel()" aria-label="Close" title="Cancel">
        <mat-icon>close</mat-icon>
      </button>
    </h2>
    <mat-dialog-content>
      <app-ou-config-editor #editor [scope]="data.scope" [initialPath]="data.path" [deferApply]="true" />
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="cancel()" [disabled]="saving()">Cancel</button>
      <button mat-flat-button color="primary" (click)="save()" [disabled]="saving()">
        {{ saving() ? 'Saving…' : (editor.pendingCount() ? 'Save (' + editor.pendingCount() + ')' : 'Save') }}
      </button>
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
  @ViewChild('editor') editor!: OuConfigEditorComponent;
  saving = signal(false);

  constructor(
    @Inject(MAT_DIALOG_DATA) public data: PolicyGpeditDialogData,
    private dialogRef: MatDialogRef<PolicyGpeditDialogComponent>,
  ) {}

  /** Commit every staged setting, then close. Closes even with nothing staged
   * (saveAll short-circuits) so Save always dismisses the dialog. */
  save(): void {
    this.saving.set(true);
    this.editor.saveAll().subscribe({
      next: () => this.dialogRef.close(true),
      error: () => this.saving.set(false),
    });
  }

  /** Drop staged edits and close without writing anything. */
  cancel(): void {
    this.editor.discardAll();
    this.dialogRef.close(false);
  }
}
