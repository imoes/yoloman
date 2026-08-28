import { Component, effect, inject, input, output, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { AgentService } from '../../../core/services/agent.service';

/** The raw-text fallback editor for a config file with no codec and no template.
 *
 * THE LAST TIER, and it is deliberately the crudest. A codec'd file is edited per key (foreign keys
 * survive); a templated file is rendered from values. This one hands the operator the file's text and
 * writes the whole thing back, which is why it is only reached when neither of the other two applies —
 * `@else if (r.raw)` in the parent, after `r.values` and the template branch.
 *
 * Fourth slice out of host-detail.component.ts. Self-contained by measurement, not by hope: the five
 * signals it owns (editingPath/editText/editBusy/editError/editPreview) had exactly one reader outside
 * this pane — cancelEdit(), called by startTemplateEdit() so the two editors could not both be open on
 * one file.
 *
 * THAT GUARD IS NOT REPRODUCED HERE, because the browser showed it is already structural. The parent
 * renders `@if (tplEditPath() === r.path) { template editor } @else if … { app-host-file-edit }`, so
 * opening the template editor DESTROYS this component rather than merely closing it — verified by
 * clicking through: after opening the template editor the element is gone from the DOM, and cancelling
 * brings the raw tier back CLOSED. I first added a templateEditPath input to re-enforce it and then
 * removed it: a second mechanism for a constraint the structure already guarantees is the redundancy
 * this consolidation is supposed to remove.
 *
 * Preview is a dry-run through the agent, which reports whether the file WOULD change. It is offered
 * because a whole-file write over a file nobody parsed deserves a look before it happens.
 */
@Component({
  selector: 'app-host-file-edit',
  standalone: true,
  imports: [MatButtonModule, MatIconModule],
  template: `
    @if (open()) {
      <textarea class="bm-cfg-edit" rows="14" [value]="text()"
                (input)="text.set($any($event.target).value)"></textarea>
      @if (error(); as e) { <p class="bm-cfg-err">{{ e }}</p> }
      @if (preview(); as p) { <p class="bm-dim">{{ p }}</p> }
      <div class="bm-rollback-actions">
        <button mat-button (click)="cancel()" [disabled]="busy()">Cancel</button>
        <button mat-button (click)="previewEdit()" [disabled]="busy()">Preview (dry-run)</button>
        <button mat-flat-button color="primary" (click)="applyEdit()" [disabled]="busy()">Apply &amp; push</button>
      </div>
    } @else {
      <!-- ONE root node in this branch on purpose: with <pre> and <button> both at the root, Angular
           reports NG8011 and the mat-icon is not projected into MatButton's icon slot, so the icon
           renders unstyled. The wrapper is the fix the compiler asks for. -->
      <div>
        <pre class="bm-cfg-values">{{ raw() }}</pre>
        <button mat-button class="bm-cfg-editbtn" (click)="start()"><mat-icon>edit</mat-icon> Edit (raw fallback)</button>
      </div>
    }
  `,
  styles: [`
    .bm-cfg-edit { width: 100%; font-family: var(--bm-mono, monospace); font-size: 12.5px; }
    .bm-cfg-values { max-height: 420px; overflow: auto; font-size: 12.5px;
      background: color-mix(in srgb, var(--mat-sys-surface-variant) 40%, transparent);
      padding: 10px 12px; border-radius: 6px; }
    .bm-cfg-editbtn { margin-top: 6px; }
    .bm-rollback-actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 10px; }
    .bm-dim { opacity: 0.62; font-size: 12.5px; }
    .bm-cfg-err { font-size: 13px; color: var(--bm-red, #d0021b); }
  `],
})
export class HostFileEditComponent {
  private agentService = inject(AgentService);

  agentId = input.required<string>();
  path = input.required<string>();
  /** The file's verbatim text, as carried by the observed state. */
  raw = input<string>('');
  /** The file was rewritten — the observed state the page shows is now stale. */
  changed = output<void>();

  open = signal(false);
  text = signal('');
  busy = signal(false);
  error = signal<string | null>(null);
  preview = signal<string | null>(null);

  constructor() {
    // Close when the page moves to another FILE. Angular reuses this instance across a path change (same
    // position in the template, new inputs), so without this the textarea would still hold the previous
    // file's text under the new file's heading — and Apply writes whatever is in the textarea.
    effect(() => {
      this.path();
      this.cancel();
    });
  }

  start(): void {
    this.text.set(this.raw());
    this.error.set(null);
    this.preview.set(null);
    this.open.set(true);
  }

  cancel(): void {
    this.open.set(false);
    this.error.set(null);
    this.preview.set(null);
  }

  private push(dryRun: boolean, onDone: (changed: boolean) => void): void {
    this.busy.set(true);
    this.error.set(null);
    this.agentService.writeFileContent(this.agentId(), this.path(), this.text(), dryRun).subscribe({
      next: (res) => {
        this.busy.set(false);
        onDone(!!res.result?.changed);
      },
      error: (e: { error?: { detail?: string } }) => {
        this.error.set(e?.error?.detail ?? 'config write failed');
        this.busy.set(false);
      },
    });
  }

  /** Dry-run: the agent reports whether the file would change, and writes nothing. */
  previewEdit(): void {
    this.push(true, (changed) =>
      this.preview.set(changed ? `preview: ${this.path()} would change (nothing written yet)`
                               : 'preview: no changes'));
  }

  /** Write the whole file, then tell the page its observed state is stale. */
  applyEdit(): void {
    this.push(false, () => {
      this.cancel();
      this.changed.emit();
    });
  }
}
