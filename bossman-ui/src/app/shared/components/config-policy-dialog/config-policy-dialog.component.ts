import { Component, Inject } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';

export interface ConfigPolicyDialogData {
  /** Human label of the scope the policy applies to, e.g. "OU /Munich/mue-0"
   * or "group web-servers". Shown in the title. */
  scopeLabel: string;
}

/** The value the dialog resolves to — the parent turns this into the
 * /config-policies request body (path + the {key: value} document, with a
 * null value when the key is being removed). */
export interface ConfigPolicyResult {
  path: string;
  format: string;
  key: string;
  removed: boolean;
  value: string;
}

/** gpedit's "add a setting to this policy", authored at OU/group scope from
 * the Policy console (Block K4). You name the config file, its codec, one
 * key, and either a value or "removed" (enforce the key's absence). Common
 * boolean-ish values are offered as suggestions (a native datalist) so you
 * can pick — like the host editor's listbox — but still type anything a
 * directive needs. The policy converges every host under the scope. */
@Component({
  selector: 'app-config-policy-dialog',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>New config setting in {{ data.scopeLabel }}</h2>
    <mat-dialog-content>
      <label class="bm-f">
        <span>Config file (absolute path)</span>
        <input [(ngModel)]="path" placeholder="/etc/ssh/sshd_config" />
      </label>
      <label class="bm-f">
        <span>Codec / format</span>
        <select [(ngModel)]="format">
          <option value="keyvalue">keyvalue (key value / key=value)</option>
          <option value="ini">ini (sections)</option>
          <option value="json">json</option>
          <option value="yaml">yaml</option>
        </select>
      </label>
      <label class="bm-f">
        <span>Setting (key{{ format === 'keyvalue' ? '' : ' — use section.key for nested' }})</span>
        <input [(ngModel)]="key" placeholder="PermitRootLogin" />
      </label>
      <div class="bm-modes">
        <label class="bm-radio"><input type="radio" name="cpmode" [checked]="!removed" (change)="removed = false" /> Configured</label>
        <label class="bm-radio"><input type="radio" name="cpmode" [checked]="removed" (change)="removed = true" /> Removed — enforce the key's absence</label>
      </div>
      @if (!removed) {
        <label class="bm-f">
          <span>Value</span>
          <input [(ngModel)]="value" list="bm-cp-values" placeholder="yes" />
          <datalist id="bm-cp-values">
            @for (v of suggestions; track v) { <option [value]="v"></option> }
          </datalist>
        </label>
      }
      @if (error) { <p class="bm-err">{{ error }}</p> }
      <p class="bm-hint">Applies to every host under this scope, per-key merged with narrower scopes (host wins). Recorded as a rollback-able generation on each host.</p>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="ref.close()">Cancel</button>
      <button mat-flat-button color="primary" (click)="save()">Create policy</button>
    </mat-dialog-actions>
  `,
  styles: [
    `
      .bm-f { display: flex; flex-direction: column; gap: 4px; margin-bottom: 14px; }
      .bm-f > span { font-size: 12px; opacity: 0.75; }
      .bm-f input, .bm-f select { padding: 8px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 14px; }
      .bm-modes { display: flex; flex-direction: column; gap: 6px; margin-bottom: 14px; }
      .bm-radio { display: flex; align-items: center; gap: 8px; font-size: 14px; cursor: pointer; }
      .bm-hint { font-size: 12px; opacity: 0.65; margin: 4px 0 0; }
      .bm-err { color: var(--mat-sys-error); font-size: 13px; margin: 4px 0 0; }
      mat-dialog-content { min-width: 420px; }
    `,
  ],
})
export class ConfigPolicyDialogComponent {
  readonly suggestions = ['yes', 'no', 'true', 'false', 'on', 'off', 'enabled', 'disabled'];
  path = '';
  format = 'keyvalue';
  key = '';
  value = '';
  removed = false;
  error: string | null = null;

  constructor(
    public ref: MatDialogRef<ConfigPolicyDialogComponent, ConfigPolicyResult>,
    @Inject(MAT_DIALOG_DATA) public data: ConfigPolicyDialogData,
  ) {}

  save(): void {
    const path = this.path.trim();
    const key = this.key.trim();
    if (!path.startsWith('/')) { this.error = 'Enter an absolute config file path.'; return; }
    if (!key) { this.error = 'Enter a setting key.'; return; }
    this.ref.close({ path, format: this.format, key, removed: this.removed, value: this.value });
  }
}
