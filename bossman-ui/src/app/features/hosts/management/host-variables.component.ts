import { Component, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatDialog } from '@angular/material/dialog';
import { ScopeVarsEditorComponent } from '../../../shared/components/scope-vars-dialog/scope-vars-editor.component';
import { ProvisionDbDialogComponent } from '../provision-db-dialog.component';

/** Variables snap-in — the host's playbook variables (host_vars).
 *
 * MOVED here from the Configuration tab, where it was a pseudo-category in that tab's own Miller
 * list. Two Miller browsers over one host is one pattern twice, and this is not a config FILE — it
 * sat beside "Security & access" and "Time synchronization" as if it were one.
 *
 * Moved, not copied. Offering it in both places would be two doors to one editor, which is fine for
 * navigation, but here it would have been two ENTRY POINTS IN THE SAME LIST — the reader could not
 * tell why a thing appears twice, and one of the two would rot.
 *
 * Thin on purpose: ScopeVarsEditorComponent already does the work and already takes a scope, so this
 * is the frame around it, not a second implementation.
 */
@Component({
  selector: 'app-host-variables',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, ScopeVarsEditorComponent],
  template: `
    <div class="bm-mgmt-section">
      <div class="bm-vars-head">
        <div>
          <h3>Variables</h3>
          <p class="bm-dim">
            Values passed to playbooks and runbooks for this host — a single value, a list or a dict.
            They resolve GPO-style (group &lt; OU &lt; host) at run time, so a host value overrides
            what its group or OU sets.
          </p>
        </div>
        <button mat-stroked-button (click)="provisionDb()">
          <mat-icon>key</mat-icon> Provision DB credential…
        </button>
      </div>
      <p class="bm-dim bm-vars-note">
        “Provision DB credential” creates a database and user on a provider and stores the credential
        here, with the password encrypted — so a playbook can reference it without it ever being
        typed into a variable by hand.
      </p>
      <app-scope-vars-editor
        [embedded]="true" scopeType="host" [scopeId]="agentId()"
        [scopeLabel]="'host ' + hostName()" [reloadTick]="reloadTick()" (saved)="onSaved()" />
    </div>
  `,
  styles: [`
    .bm-vars-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; }
    .bm-vars-head h3 { margin: 0; }
    .bm-dim { opacity: 0.62; margin: 2px 0 0; font-size: 13px; max-width: 78ch; }
    .bm-vars-note { margin-bottom: 12px; }
  `],
})
export class HostVariablesComponent {
  private dialog = inject(MatDialog);
  agentId = input.required<string>();
  hostName = input<string>('');

  /** Bumped to make the editor re-read after something outside it wrote a variable — the provision
   * dialog does exactly that, and without the tick the new credential would be invisible until the
   * snap-in was reopened. */
  reloadTick = signal(0);

  provisionDb(): void {
    const ref = this.dialog.open(ProvisionDbDialogComponent, {
      width: '640px', data: { consumerAgentId: this.agentId(), consumerName: this.hostName() },
    });
    ref.afterClosed().subscribe((ok) => { if (ok) this.reloadTick.update((t) => t + 1); });
  }

  onSaved(): void {
    this.reloadTick.update((t) => t + 1);
  }
}
