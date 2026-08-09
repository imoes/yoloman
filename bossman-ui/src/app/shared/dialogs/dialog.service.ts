import { Injectable, inject } from '@angular/core';
import { MatDialog } from '@angular/material/dialog';
import { MatSnackBar } from '@angular/material/snack-bar';
import { firstValueFrom } from 'rxjs';
import { AppDialogComponent, AppDialogData } from './app-dialog.component';

/**
 * In-app replacements for the browser's confirm()/prompt()/alert(), which
 * some browsers suppress (breaking destructive actions). confirm/prompt use a
 * Material dialog; notify uses a snackbar.
 */
@Injectable({ providedIn: 'root' })
export class DialogService {
  private dialog = inject(MatDialog);
  private snack = inject(MatSnackBar);

  /** Resolves true if confirmed, false otherwise. */
  async confirm(opts: Omit<AppDialogData, 'input'>): Promise<boolean> {
    const ref = this.dialog.open(AppDialogComponent, { data: opts, width: '440px' });
    return (await firstValueFrom(ref.afterClosed())) === true;
  }

  /** Resolves to the entered string, or null if cancelled. */
  async prompt(opts: AppDialogData & { input: NonNullable<AppDialogData['input']> }): Promise<string | null> {
    const ref = this.dialog.open(AppDialogComponent, { data: opts, width: '440px' });
    const res = await firstValueFrom(ref.afterClosed());
    return typeof res === 'string' ? res : null;
  }

  /** A transient toast (replaces alert() for status/errors). */
  notify(message: string, kind: 'info' | 'error' = 'info'): void {
    this.snack.open(message, 'Dismiss', {
      duration: kind === 'error' ? 8000 : 4000,
      panelClass: kind === 'error' ? 'bm-snack-error' : 'bm-snack-info',
    });
  }
}
