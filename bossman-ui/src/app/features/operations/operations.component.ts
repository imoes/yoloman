import { Component, OnInit, inject, signal } from '@angular/core';
import { DatePipe, DecimalPipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { RouterLink } from '@angular/router';
import { OperationsService, OperationRecord, OperationOutcome } from '../../core/services/operations.service';

/**
 * THE RESULT LOG: what the fleet's hosts DID, and what came back.
 *
 * The human half of the same record the AI reads through the `operation_log` MCP tool — deliberately the same
 * rows and the same words, because a summary written for one reader and a record kept for the other is how the
 * two end up disagreeing about what happened.
 *
 * WHY IT IS NOT THE AUDIT LOG, stated in the page itself: the audit log records what somebody asked this
 * SERVER to do; this records what a HOST did. Two pages because they are two facts, and the header says which
 * is which so nobody has to guess from the columns.
 */
@Component({
  selector: 'app-operations',
  standalone: true,
  imports: [DatePipe, DecimalPipe, FormsModule, MatButtonModule, MatIconModule, RouterLink],
  template: `
    <div class="bm-page">
      <div class="bm-head">
        <div>
          <h1>Result log</h1>
          <p class="bm-dim">
            What hosts DID, and what came back — module, verdict, and the evidence behind it (exit code, the
            plan the host produced for itself, its own refusal text). Not the
            <a routerLink="/audit">audit log</a>, which records what was asked of <em>this server</em>.
          </p>
        </div>
        <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Reload</button>
      </div>

      <!-- The verdict spread first: this is the number an operator scans for, and each outcome is its own
           thing — a "planned" preview and an "unchanged" no-op are not the same answer. -->
      <div class="bm-summary">
        <span class="bm-pill bm-pill--total">{{ rows().length }} operations</span>
        @for (o of spread(); track o[0]) {
          <span class="bm-pill bm-out bm-out--{{ o[0] }}" (click)="setOutcome(o[0])" [title]="hint(o[0])">
            {{ o[1] }} {{ o[0] }}
          </span>
        }
      </div>

      <div class="bm-filters">
        <input placeholder="host" [(ngModel)]="fHost" (keyup.enter)="reload()" />
        <input placeholder="module" [(ngModel)]="fModule" (keyup.enter)="reload()" class="bm-mono" />
        <select [(ngModel)]="fOutcome" (ngModelChange)="reload()">
          <option value="">any outcome</option>
          @for (o of outcomes(); track o) { <option [value]="o">{{ o }}</option> }
        </select>
        <select [(ngModel)]="fSince" (ngModelChange)="reload()">
          <option value="0">any time</option>
          <option value="60">last hour</option>
          <option value="1440">last 24 h</option>
          <option value="10080">last 7 days</option>
        </select>
        <label class="bm-check">
          <input type="checkbox" [(ngModel)]="fChanged" (ngModelChange)="reload()" />
          changes only
        </label>
        <button mat-stroked-button (click)="reload()"><mat-icon>search</mat-icon> Search</button>
      </div>

      <div class="bm-table-wrap">
        <table class="bm-table">
          <thead>
            <tr>
              <th>When</th><th>Host</th><th>Module</th><th>Outcome</th><th>Took</th><th>Asked by</th><th>What it said</th><th></th>
            </tr>
          </thead>
          <tbody>
            @for (r of rows(); track r.id) {
              <tr [class.bm-attn]="attention(r)">
                <td class="bm-nowrap bm-dim">{{ (r.started_at || r.collected_at) | date:'MM-dd HH:mm:ss' }}</td>
                <td>{{ r.host || '—' }}</td>
                <td class="bm-mono">{{ r.module }}</td>
                <td>
                  <span class="bm-out bm-out--{{ r.outcome }}" [title]="hint(r.outcome)">{{ r.outcome }}</span>
                </td>
                <td class="bm-nowrap bm-dim">{{ r.duration_ms != null ? (r.duration_ms | number:'1.0-0') + ' ms' : '—' }}</td>
                <td class="bm-dim bm-ident">{{ short(r.identity) }}</td>
                <td class="bm-said">{{ r.message || r.error || '—' }}</td>
                <td>
                  @if (r.evidence || r.params || r.error) {
                    <button mat-icon-button (click)="toggle(r.id)" [attr.aria-label]="'evidence for ' + r.module">
                      <mat-icon>{{ open().has(r.id) ? 'expand_less' : 'expand_more' }}</mat-icon>
                    </button>
                  }
                </td>
              </tr>
              @if (open().has(r.id)) {
                <tr class="bm-detail">
                  <td colspan="8">
                    <!-- PROGRESSIVE DISCLOSURE, and the reason the evidence is kept verbatim: the verdict is
                         a claim, this is what it rests on. -->
                    <div class="bm-kv"><span>call</span><code>{{ r.module }}{{ r.dry_run ? ' (dry run)' : '' }}</code></div>
                    <div class="bm-kv"><span>record</span><code>{{ r.record_id || r.id }} · seq {{ r.seq }} · boot {{ r.boot_id.slice(0, 8) }}</code></div>
                    @if (r.params) { <div class="bm-kv"><span>parameters</span><pre>{{ pretty(r.params) }}</pre></div> }
                    @if (r.error) { <div class="bm-kv"><span>the host said</span><pre class="bm-err">{{ r.error }}</pre></div> }
                    @if (r.evidence) { <div class="bm-kv"><span>evidence</span><pre>{{ pretty(r.evidence) }}</pre></div> }
                  </td>
                </tr>
              }
            } @empty {
              <tr><td colspan="8" class="bm-dim">
                No operations match. An empty result means nothing was collected for this filter — not that
                nothing happened: an agent keeps its last 1000 calls, and anything older is only here if it
                was collected in time.
              </td></tr>
            }
          </tbody>
        </table>
      </div>
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1400px; margin: 0 auto; }
    .bm-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; }
    .bm-head h1 { margin: 0; }
    .bm-dim { opacity: 0.62; }
    .bm-summary { display: flex; gap: 8px; flex-wrap: wrap; margin: 14px 0; }
    .bm-pill { font-size: 12px; padding: 3px 12px; border-radius: 12px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-pill--total { font-weight: 600; }
    .bm-summary .bm-out { cursor: pointer; }
    .bm-filters { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 14px; align-items: center; }
    .bm-filters input, .bm-filters select { padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; }
    .bm-check { display: flex; align-items: center; gap: 6px; font-size: 13px; }
    .bm-mono, code, pre { font-family: ui-monospace, monospace; }
    .bm-table-wrap { overflow-x: auto; }
    .bm-table { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-table th { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant);
      font-size: 11px; text-transform: uppercase; opacity: 0.6; }
    .bm-table td { padding: 6px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); vertical-align: top; }
    .bm-nowrap { white-space: nowrap; }
    .bm-ident { max-width: 170px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bm-said { max-width: 520px; }
    /* Attention is for the two outcomes that need a decision, not for everything that is not "changed". */
    .bm-attn { background: color-mix(in srgb, var(--bm-amber, #ef6c00) 8%, transparent); }
    .bm-out { font-size: 11px; padding: 1px 8px; border-radius: 9px; white-space: nowrap;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
    .bm-out--changed { background: color-mix(in srgb, var(--bm-green, #2e7d32) 24%, transparent); }
    .bm-out--planned { background: color-mix(in srgb, #1565c0 26%, transparent); }
    .bm-out--refused { background: color-mix(in srgb, var(--bm-amber, #ef6c00) 30%, transparent); }
    .bm-out--error { background: color-mix(in srgb, var(--bm-red, #c62828) 28%, transparent); }
    .bm-out--timed-out { background: color-mix(in srgb, #6a1b9a 28%, transparent); }
    .bm-out--unknown-module { background: color-mix(in srgb, #ad1457 24%, transparent); }
    .bm-out--gap { background: color-mix(in srgb, var(--mat-sys-on-surface) 22%, transparent); font-style: italic; }
    .bm-detail td { background: color-mix(in srgb, var(--mat-sys-on-surface) 4%, transparent); }
    .bm-kv { display: flex; gap: 12px; margin: 4px 0; }
    .bm-kv > span { min-width: 100px; font-size: 11px; text-transform: uppercase; opacity: 0.55; padding-top: 3px; }
    .bm-kv pre { margin: 0; white-space: pre-wrap; word-break: break-word; max-height: 320px; overflow: auto;
      font-size: 12px; flex: 1; }
    .bm-err { color: var(--bm-red, #c62828); }
  `],
})
export class OperationsComponent implements OnInit {
  private svc = inject(OperationsService);
  rows = signal<OperationRecord[]>([]);
  outcomes = signal<OperationOutcome[]>([]);
  open = signal<Set<string>>(new Set());
  fHost = '';
  fModule = '';
  fOutcome = '';
  fSince = '0';
  fChanged = false;

  /** What each outcome MEANS, on hover — the vocabulary is only useful if its distinctions survive the trip
   * to the reader. `timed-out` is the one that matters most: it is not a failure. */
  private hints: Record<string, string> = {
    changed: 'the host is different now',
    unchanged: 'it was already as asked — the idempotence claim',
    planned: 'a dry run: a preview, nothing was done',
    refused: 'the host said no; its own words are in the evidence',
    error: 'the agent broke — a fact about us, not the host',
    'timed-out': 'the caller stopped waiting — THE OPERATION MAY HAVE COMPLETED; re-read the state',
    'unknown-module': 'a call for a tool this host does not have',
    gap: 'records fell out of the agent’s ring before collection: that range is gone',
  };

  ngOnInit(): void { this.reload(); }

  reload(): void {
    const since = Number(this.fSince) > 0
      ? new Date(Date.now() - Number(this.fSince) * 60_000).toISOString()
      : undefined;
    this.svc.list({
      host: this.fHost.trim() || undefined,
      module: this.fModule.trim() || undefined,
      outcome: this.fOutcome || undefined,
      since,
      changed_only: this.fChanged,
      limit: 500,
    }).subscribe((page) => {
      this.rows.set(page.operations);
      this.outcomes.set(page.outcomes);
    });
  }

  setOutcome(outcome: string): void {
    this.fOutcome = this.fOutcome === outcome ? '' : outcome;
    this.reload();
  }

  toggle(id: string): void {
    const next = new Set(this.open());
    next.has(id) ? next.delete(id) : next.add(id);
    this.open.set(next);
  }

  spread(): [string, number][] {
    const counts = new Map<string, number>();
    for (const r of this.rows()) counts.set(r.outcome, (counts.get(r.outcome) ?? 0) + 1);
    return [...counts.entries()].sort((a, b) => b[1] - a[1]);
  }

  /** Highlighted rows are the ones that need a decision — a refusal, our own error, and a timeout whose real
   * outcome is unknown. `unchanged` is not a problem and must not be dressed as one. */
  attention(r: OperationRecord): boolean {
    return r.outcome === 'refused' || r.outcome === 'error' || r.outcome === 'timed-out' || r.outcome === 'gap';
  }

  hint(outcome: string): string { return this.hints[outcome] ?? outcome; }

  short(identity: string | null): string {
    if (!identity) return '—';
    const cn = /CN=([^,]+)/.exec(identity);
    return cn ? cn[1] : identity;
  }

  pretty(value: unknown): string {
    try { return JSON.stringify(value, null, 2); } catch { return String(value); }
  }
}
