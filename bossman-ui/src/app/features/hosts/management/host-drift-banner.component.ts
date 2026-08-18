import { Component, input, output, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { StateResourceChange } from '../../../core/models/agent.model';
import { driftRows } from './drift-rows';

/** "Does this host still look the way policy says it should?" — managed files versus their desired config.
 *
 * THREE states, all named: in sync, drifted, and NOT COMPARABLE. The third was missing and cost a bug — see
 * changed()/unreadable(). Each is worth saying out loud, which is why the in-sync case is not silent: "12
 * managed file(s), all in sync with desired" is information, and an empty banner would leave "no drift" and
 * "nothing is managed" looking identical. Nothing at all is shown only when the host has no managed files,
 * because then there is genuinely no claim to check.
 *
 * Seventh slice out of host-detail.component.ts, and a presentational one: the drift DATA stays on the
 * page because the settings table reads the same signal (desired values and per-key sources come from it),
 * so moving the state would have split one fact across two owners. What moved is the banner, the diff
 * table, and the open/closed toggle — which nothing else reads.
 */
@Component({
  selector: 'app-host-drift-banner',
  standalone: true,
  imports: [MatButtonModule, MatIconModule],
  template: `
    @if (managed().length) {
      <div class="bm-drift-banner" [class.bm-drift-on]="changed().length || unreadable().length">
        <mat-icon>{{ changed().length ? 'sync_problem' : (unreadable().length ? 'help' : 'verified') }}</mat-icon>
        @if (changed().length) {
          <span>{{ changed().length }} of {{ managed().length }} managed file(s) drifted from desired.@if (unreadable().length) { {{ unreadable().length }} could not be compared.}</span>
        } @else if (unreadable().length) {
          <span>{{ managed().length - unreadable().length }} of {{ managed().length }} managed file(s) in
            sync; {{ unreadable().length }} could not be compared.</span>
        } @else {
          <span>{{ managed().length }} managed file(s), all in sync with desired.</span>
        }
        @if (changed().length || unreadable().length) {
          <button mat-button (click)="open.set(!open())">{{ open() ? 'Hide' : 'Show' }} detail</button>
        }
        @if (changed().length) {
          <button mat-flat-button color="primary" (click)="resync.emit()" [disabled]="busy()">Re-sync to desired</button>
        }
      </div>
      @if (open() && unreadable().length) {
        <div class="bm-drift-diff">
          @for (c of unreadable(); track c.path) {
            <div class="bm-drift-file">
              <div class="bm-drift-fname" (click)="openFile.emit(c.path)" title="Open this file">
                <mat-icon>help</mat-icon>{{ c.path }}
                <span class="bm-drift-n">not compared</span>
              </div>
              <p class="bm-drift-why">{{ c.error }}</p>
            </div>
          }
        </div>
      }
      @if (changed().length && open()) {
        <div class="bm-drift-diff">
          @for (c of changed(); track c.path) {
            <div class="bm-drift-file">
              <div class="bm-drift-fname" (click)="openFile.emit(c.path)" title="Open this file">
                <mat-icon>description</mat-icon>{{ c.path }}
                <span class="bm-drift-n">{{ rows(c).length }} change(s)</span>
              </div>
              <table class="bm-drift-tbl">
                <thead><tr><th>Setting</th><th>Live (on host)</th><th></th><th>Desired</th></tr></thead>
                <tbody>
                  @for (d of rows(c); track d.key) {
                    <tr>
                      <td class="bm-mono">{{ d.key }}</td>
                      <td class="bm-mono bm-drift-live">{{ d.live }}</td>
                      <td class="bm-drift-arrow">→</td>
                      <td class="bm-mono bm-drift-want">{{ d.desired }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            </div>
          }
        </div>
      }
    }
  `,
  /* Carried over VERBATIM from host-detail's stylesheet, not re-designed. The first draft of this
     component invented its own palette (primary/amber, muted live value) and would have silently changed
     what the screen means: in-sync is GREEN, drift is ORANGE, and in the diff the live value is red
     against a green desired one — the colour is part of the reading, and an extraction that alters it is
     a redesign nobody asked for. */
  styles: [`
    .bm-drift-banner { display: flex; align-items: center; gap: 10px; padding: 8px 12px; margin-bottom: 12px; border-radius: 8px; background: color-mix(in srgb, var(--bm-green, #2e7d32) 12%, transparent); font-size: 13px; }
    .bm-drift-banner.bm-drift-on { background: color-mix(in srgb, var(--bm-warn, #ef6c00) 16%, transparent); }
    .bm-drift-banner mat-icon { flex: 0 0 auto; }
    .bm-drift-diff { margin: 0 0 12px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 8px 12px; }
    .bm-drift-file { margin: 6px 0; }
    .bm-drift-fname { display: flex; align-items: center; gap: 6px; font-family: ui-monospace, monospace; font-size: 12.5px; cursor: pointer; }
    .bm-drift-fname:hover { color: var(--mat-sys-primary); }
    .bm-drift-fname mat-icon { font-size: 16px; height: 16px; width: 16px; opacity: 0.7; }
    .bm-drift-n { opacity: 0.6; font-family: inherit; font-size: 11px; }
    .bm-drift-tbl { width: 100%; border-collapse: collapse; font-size: 12px; margin: 4px 0 2px; }
    .bm-drift-tbl th { text-align: left; font-size: 10.5px; opacity: 0.6; padding: 2px 10px; font-weight: 500; }
    .bm-drift-tbl td { padding: 2px 10px; border-top: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 60%, transparent); }
    .bm-drift-live { color: var(--mat-sys-error, #c62828); }
    .bm-drift-want { color: var(--bm-green, #2e7d32); }
    .bm-drift-arrow { opacity: 0.5; }
    /* The reason a file could not be compared, quoted from the agent. */
    .bm-drift-why { margin: 4px 0 0; font-size: 12px; opacity: 0.75; font-family: ui-monospace, monospace; }
    .bm-mono { font-family: ui-monospace, monospace; }
  `],
})
export class HostDriftBannerComponent {
  /** Paths the host has a recorded desired config for. */
  managed = input<string[]>([]);
  /** What the API returns as "drift" — see changed()/unreadable(): it is not all drift. */
  drifted = input<StateResourceChange[]>([]);
  /** A re-sync is in flight (owned by the page, which issues it). */
  busy = input(false);

  /** Converge the whole host back to its recorded desired config. */
  resync = output<void>();
  /** Select this file in the Miller columns — the diff names a file, so it should be reachable from it. */
  openFile = output<string>();

  open = signal(false);

  rows = driftRows;

  /** Files that really differ from desired: at least one key changed.
   *
   * FOUND BY CLICKING THIS BANNER. It said "1 of 10 managed file(s) drifted" and then showed a file with
   * "0 change(s)" and an empty table — a state asserting a difference with no reachable cause. The payload
   * explained it: /etc/motd came back `action: "noop"` with
   * `error: read: config: unsupported format "raw"`. The agent could not READ the file as a codec'd
   * config, so nothing was compared, and the API had put that entry in the drift list anyway.
   *
   * A failed comparison is not a difference. Counting it as drift claims a deviation nobody measured, and
   * "Re-sync to desired" would then offer to fix something that was never diagnosed. */
  changed(): StateResourceChange[] {
    return this.drifted().filter((c) => Object.keys(c.changed ?? {}).length > 0);
  }

  /** Files that could NOT be compared, with the reason the API already carries.
   *
   * This is the third state the banner was missing: in sync / drifted / not comparable. It used to be
   * folded into "drifted", and the `error` field — which says exactly why — was dropped on the floor. */
  unreadable(): StateResourceChange[] {
    return this.drifted().filter((c) => !Object.keys(c.changed ?? {}).length && !!c.error);
  }
}
