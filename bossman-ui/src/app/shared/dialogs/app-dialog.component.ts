import { Component, Inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';

export interface AppDialogData {
  title: string;
  message?: string;
  confirmText?: string;
  cancelText?: string;
  danger?: boolean;
  /** When set, the dialog shows a text input and resolves to its value. */
  input?: { label?: string; value?: string; placeholder?: string };
}

/**
 * The single in-app dialog for confirmations and simple text prompts — a
 * Material dialog replacing the browser's confirm()/prompt(), which some
 * browsers (and stricter Firefox setups) suppress entirely, silently breaking
 * destructive actions like "delete user".
 */
@Component({
  selector: 'app-dialog',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatButtonModule, MatFormFieldModule, MatInputModule],
  template: `
    <h2 mat-dialog-title>{{ data.title }}</h2>
    <mat-dialog-content>
      @if (data.message) { <p class="bm-msg">{{ data.message }}</p> }
      @if (data.input) {
        <mat-form-field appearance="outline" class="bm-input">
          <mat-label>{{ data.input.label || 'Value' }}</mat-label>
          <input matInput [(ngModel)]="value" [placeholder]="data.input.placeholder || ''"
                 (keyup.enter)="confirm()" cdkFocusInitial />
        </mat-form-field>
      }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="cancel()">{{ data.cancelText || 'Cancel' }}</button>
      <button mat-raised-button [color]="data.danger ? 'warn' : 'primary'" (click)="confirm()">
        {{ data.confirmText || 'OK' }}
      </button>
    </mat-dialog-actions>
  `,
  styles: [`
    .bm-msg { margin: 0 0 8px; max-width: 460px; }
    .bm-input { width: 100%; min-width: 320px; }
  `],
})
export class AppDialogComponent {
  value: string;
  constructor(
    public ref: MatDialogRef<AppDialogComponent, boolean | string>,
    @Inject(MAT_DIALOG_DATA) public data: AppDialogData,
  ) {
    this.value = data.input?.value ?? '';
  }

  confirm(): void {
    this.ref.close(this.data.input ? this.value : true);
  }

  cancel(): void {
    this.ref.close(this.data.input ? undefined : false);
  }
}
