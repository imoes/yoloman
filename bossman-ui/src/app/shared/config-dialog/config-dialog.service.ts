import { Injectable, inject } from '@angular/core';
import { MatDialog } from '@angular/material/dialog';
import { Observable } from 'rxjs';
import { ConfigDialogComponent } from './config-dialog.component';
import { ConfigDialogDef } from './config-dialog.types';

/** Opens a declarative config dialog (Cockpit's dialog_open equivalent) and
 * resolves with the action's result, or undefined if the user cancelled. */
@Injectable({ providedIn: 'root' })
export class ConfigDialogService {
  private dialog = inject(MatDialog);

  open<T = unknown>(def: ConfigDialogDef): Observable<T | undefined> {
    return this.dialog.open(ConfigDialogComponent, { data: def, autoFocus: false, restoreFocus: false }).afterClosed();
  }
}
