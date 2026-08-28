import { Component, effect, inject, input, output, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { Agent, StateGeneration, StatePlan } from '../../../core/models/agent.model';
import { AgentService } from '../../../core/services/agent.service';

/** Generation history + rollback for the host's desired state (Block F2).
 *
 * Second slice out of host-detail.component.ts, and the cleanest one so far: it owns BOTH its data
 * and its UI. That is the difference from the thresholds pane, where the list had to stay with the
 * page because a category badge counts it. Here nothing else on the page reads `generations`, so
 * keeping the fetch in the parent's loadObserved() was state held on behalf of one child.
 *
 * `changed` fires after a rollback is APPLIED: the observed state the page shows is stale the moment
 * the host is rewritten, and a child must not reach into its parent to refresh it.
 *
 * FIRST ATTEMPT AT THIS SLICE WAS REVERTED. It cut the members by a computed line range using a
 * combined brace/paren balance, which over-ran and deleted a NEIGHBOURING member (healthStatus, which
 * sits immediately after the rollback signals) and extracted one block twice. The compiler caught it,
 * the working tree was reset, and this version was built by reading each block and moving it with an
 * exact-text edit — which fails loudly instead of silently taking the wrong lines.
 */
@Component({
  selector: 'app-host-config-generations',
  standalone: true,
  imports: [DatePipe, MatButtonModule, MatCardModule],
  template: `
    @if (generations().length) {
      <h3 class="bm-cfg-gen-h">Generations</h3>
      <table class="bm-cfg-gen">
        <thead><tr><th>#</th><th>Applied</th><th>Hash</th><th>Resources</th><th></th></tr></thead>
        <tbody>
          @for (g of generations(); track g.number) {
            <tr [class.bm-gen-current]="isCurrentGeneration(g.number)">
              <td>{{ g.number }}</td>
              <td>{{ g.applied_at | date: 'medium' }}</td>
              <td><code>{{ g.hash.slice(0, 12) }}…</code></td>
              <td>{{ g.resources }}</td>
              <td>
                @if (isCurrentGeneration(g.number)) {
                  <span class="bm-tag">current</span>
                } @else {
                  <button mat-button (click)="previewRollback(g.number)" [disabled]="rollbackBusy()">Roll back to #{{ g.number }}…</button>
                }
              </td>
            </tr>
          }
        </tbody>
      </table>

      @if (rollbackTarget() !== null) {
        <mat-card class="bm-rollback">
          <div class="bm-rollback-head">
            <strong>Roll back to generation #{{ rollbackTarget() }}</strong>
            <span class="bm-dim">— dry-run preview, nothing applied yet</span>
          </div>
          @if (rollbackBusy() && !rollbackPlan()) {
            <p class="bm-empty">Computing the diff…</p>
          } @else if (rollbackError(); as rerr) {
            <p class="bm-cfg-err">{{ rerr }}</p>
          } @else if (rollbackPlan(); as plan) {
            @if (rollbackDiffRows().length) {
              <table class="bm-diff">
                <thead><tr><th>File</th><th>Action</th><th>Change</th></tr></thead>
                <tbody>
                  @for (d of rollbackDiffRows(); track d.path + d.detail) {
                    <tr><td><code>{{ d.path }}</code></td><td>{{ d.action }}</td><td>{{ d.detail }}</td></tr>
                  }
                </tbody>
              </table>
            } @else {
              <p class="bm-dim">No changes — the host already matches generation #{{ rollbackTarget() }}.</p>
            }
          }
          <div class="bm-rollback-actions">
            <button mat-button (click)="cancelRollback()" [disabled]="rollbackBusy()">Cancel</button>
            <button mat-flat-button color="warn" (click)="applyRollback()"
                    [disabled]="rollbackBusy() || !rollbackPlan() || !rollbackDiffRows().length">
              Apply rollback
            </button>
          </div>
        </mat-card>
      }
    }
  `,
  styles: [`
    .bm-cfg-gen-h { margin: 18px 0 6px; font-size: 14px; }
    .bm-cfg-gen, .bm-diff { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-cfg-gen th, .bm-diff th { text-align: left; font-size: 12px; opacity: 0.6; padding: 6px 10px; }
    .bm-cfg-gen td, .bm-diff td { padding: 7px 10px; border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-gen-current { background: color-mix(in srgb, var(--mat-sys-primary) 8%, transparent); }
    .bm-tag { font-size: 11px; padding: 1px 8px; border-radius: 10px;
      background: color-mix(in srgb, var(--mat-sys-primary) 22%, transparent); }
    .bm-rollback { margin-top: 12px; padding: 12px 14px; }
    .bm-rollback-head { display: flex; align-items: baseline; gap: 8px; margin-bottom: 8px; }
    /* The rollback action is destructive, so it reads as one rather than as a neutral button. */
    .bm-rollback-actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 10px; }
    .bm-dim { opacity: 0.62; font-size: 12.5px; }
    .bm-empty { opacity: 0.6; font-size: 13px; }
    .bm-cfg-err { font-size: 13px; color: var(--bm-red, #d0021b); }
  `],
})
export class HostConfigGenerationsComponent {
  private agentService = inject(AgentService);

  agent = input.required<Agent>();
  /** Bumped by the page whenever it re-reads the observed state.
   *
   * A rollback preview is a dry-run diff against the observed state AS IT WAS. Once the page re-reads
   * it, that diff may no longer describe reality, so the preview is discarded rather than left on
   * screen looking authoritative. The parent used to clear this directly (loadObserved() reset
   * rollbackTarget/rollbackPlan); with the state down here it needs telling instead, and a tick is the
   * pattern this codebase already uses for exactly that (see the Variables snap-in). */
  reloadTick = input(0);
  /** The host was rewritten — whatever the page shows as "observed" is now stale. */
  changed = output<void>();

  // Block F2 — generation history + rollback.
  generations = signal<StateGeneration[]>([]);
  rollbackTarget = signal<number | null>(null); // generation being previewed
  rollbackPlan = signal<StatePlan | null>(null); // dry-run diff for that target
  rollbackBusy = signal(false);
  rollbackError = signal<string | null>(null);

  constructor() {
    // Reload when pointed at a different host, not only on construction: a generation list belonging
    // to the previously selected host would be worse than an empty one, because it looks valid. The
    // tick is read in the same effect so a page reload both refreshes the history and drops a preview
    // that no longer matches what was read.
    effect(() => {
      this.agent();
      this.reloadTick();
      this.cancelRollback();
      this.load();
    });
  }

  /** Its own fetch. It used to ride along inside the parent's loadObserved(), whose own comment
   * already said it was "independent of the observed read". */
  private load(): void {
    const agent = this.agent();
    if (!agent) return;
    this.agentService.stateGenerations(agent.id).subscribe({
      next: (res) => this.generations.set(res.generations ?? []),
      error: () => this.generations.set([]),
    });
  }

  /** True for the newest generation — the one currently applied. */
  isCurrentGeneration(n: number): boolean {
    const gens = this.generations();
    return gens.length > 0 && n === Math.max(...gens.map((g) => g.number));
  }

  /** Preview a rollback to generation `n`: a dry-run whose plan IS the
   * observed→target diff. Nothing is written. */
  previewRollback(n: number): void {
    const agent = this.agent();
    if (!agent) return;
    this.rollbackTarget.set(n);
    this.rollbackPlan.set(null);
    this.rollbackError.set(null);
    this.rollbackBusy.set(true);
    this.agentService.stateRollback(agent.id, n, true).subscribe({
      next: (res) => {
        this.rollbackPlan.set(res.plan);
        this.rollbackBusy.set(false);
      },
      error: (e) => {
        this.rollbackError.set(e?.error?.detail ?? 'rollback preview failed');
        this.rollbackBusy.set(false);
      },
    });
  }

  cancelRollback(): void {
    this.rollbackTarget.set(null);
    this.rollbackPlan.set(null);
    this.rollbackError.set(null);
  }

  /** Apply the previewed rollback for real, then tell the page to reload. */
  applyRollback(): void {
    const agent = this.agent();
    const n = this.rollbackTarget();
    if (!agent || n === null) return;
    this.rollbackBusy.set(true);
    this.rollbackError.set(null);
    this.agentService.stateRollback(agent.id, n, false).subscribe({
      next: () => {
        this.rollbackBusy.set(false);
        this.cancelRollback();
        this.changed.emit();
        this.load();   // the applied generation is now the current one
      },
      error: (e) => {
        this.rollbackError.set(e?.error?.detail ?? 'rollback failed');
        this.rollbackBusy.set(false);
      },
    });
  }

  /** Flatten a plan's non-noop changes into readable "path: key before→after"
   * rows for the rollback preview. */
  rollbackDiffRows(): { path: string; action: string; detail: string }[] {
    const plan = this.rollbackPlan();
    if (!plan) return [];
    const rows: { path: string; action: string; detail: string }[] = [];
    for (const c of plan.changes) {
      if (c.action === 'noop') continue;
      if (c.changed && Object.keys(c.changed).length) {
        for (const [k, [before, after]] of Object.entries(c.changed)) {
          rows.push({ path: c.path, action: c.action, detail: `${k}: ${JSON.stringify(before)} → ${JSON.stringify(after)}` });
        }
      } else {
        rows.push({ path: c.path, action: c.action, detail: c.error ? `error: ${c.error}` : c.action });
      }
    }
    return rows;
  }
}
